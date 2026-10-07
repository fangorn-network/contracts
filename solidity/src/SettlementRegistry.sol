// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {NonReentrant} from "./NonReentrant.sol";

/// The slice of Semaphore this contract calls.
interface ISemaphore {
    struct SemaphoreProof {
        uint256 merkleTreeDepth;
        uint256 merkleTreeRoot;
        uint256 nullifier;
        uint256 message;
        uint256 scope;
        uint256[8] points;
    }

    function createGroup() external returns (uint256);
    function addMember(uint256 groupId, uint256 identityCommitment) external;
    function validateProof(uint256 groupId, SemaphoreProof calldata proof) external;
}

/// SettlementRegistry
///
/// Uses Semaphore alongside ERC-3009 `transferWithAuthorization` to enable a
/// private-payment-for-content mechanism.
///
/// * **One Semaphore group per resource.**
/// * **Derived resourceIds** as keccak(publisher ++ uid)
///
/// A port of `stylus/settlement_registry`. The ABI is the same — function, error and
/// event names, argument order, and event field names — so existing clients talk to
/// either without change. That includes `settle`'s `hook_data`, which is `uint8[]`
/// rather than `bytes` because the Stylus contract declared it `Vec<u8>`.
///
/// Every external call is low-level on purpose. The Stylus contract maps each failed
/// call to its own error, and a low-level call is what lets this one do the same.
///
/// Deployed behind an ERC-1967 proxy (UUPS): the proxy holds the state and the address
/// (it is the proxy that administers the Semaphore groups), and the admin can point it
/// at a new implementation. Storage is therefore append-only: add state variables
/// after the last one, and never reorder, retype or remove what is there
/// (`scripts/layout.sh` checks).
contract SettlementRegistry is Initializable, UUPSUpgradeable, NonReentrant {
    event MemberRegistered(bytes32 indexed resourceId, uint256 identityCommitment);
    event SettlementFinalized(bytes32 indexed resourceId, uint256 indexed nullifierHash, uint256 message);
    event HookRegistered(bytes32 indexed resourceId, address hook);
    event ResourceCreated(bytes32 indexed resourceId, address owner, uint256 price, uint256 groupId, string uri);
    event PriceUpdated(bytes32 indexed resourceId, address owner, uint256 price);
    event ResourceDisabled(bytes32 indexed resourceId, bool disabled, address by);
    event AdminChanged(address previousAdmin, address newAdmin);

    error AlreadyRegistered();
    error AlreadySettled();
    error IncorrectPaymentAmount();
    error TransferFailed();
    error VerificationFailed();
    error NotResourceOwner();
    error ResourceNotFound();
    error HookFailed();
    error SemaphoreCallFailed();
    error ResourceIsDisabled();
    error NotAdmin();

    address internal usdc;
    address internal semaphore;
    /// Can be zero: then nobody but a resource's owner can take it down.
    address internal admin;

    mapping(bytes32 => uint256) internal resourcePrice;
    mapping(bytes32 => address) internal resourceOwners;
    mapping(bytes32 => string) internal resourceUris;
    mapping(bytes32 => address) internal resourceHooks;
    /// per-resource Semaphore groups
    mapping(bytes32 => uint256) internal resourceGroups;
    mapping(bytes32 => bool) internal resourceDisabled;
    /// nullifier => spent
    mapping(uint256 => bool) internal nullifiers;
    /// stealth address => resource => settled
    mapping(address => mapping(bytes32 => bool)) internal settlements;
    /// resource => identity commitment => registered
    mapping(bytes32 => mapping(uint256 => bool)) internal registrations;

    /// The implementation is only ever used through a proxy. Lock it, so nobody can
    /// initialize it directly.
    constructor() {
        _disableInitializers();
    }

    /// Takes the place of a constructor: runs once, in the proxy's storage, as part of
    /// the proxy's deployment.
    function initialize(address usdc_, address semaphore_, address admin_) external initializer {
        usdc = usdc_;
        semaphore = semaphore_;
        admin = admin_;
        emit AdminChanged(address(0), admin_);
    }

    /// Only the admin may point the proxy at a new implementation. A registry with no
    /// admin can never be upgraded.
    function _authorizeUpgrade(address) internal view override {
        address current = admin;
        if (msg.sender != current || current == address(0)) revert NotAdmin();
    }

    /// Set a new admin (has global takedown authority). Setting zero renounces it
    /// for good.
    function setAdmin(address new_admin) external {
        address current = admin;
        if (msg.sender != current || current == address(0)) revert NotAdmin();
        admin = new_admin;
        emit AdminChanged(current, new_admin);
    }

    /// Create a resource and its Semaphore group.
    /// The resourceId is `keccak(publisher ++ uid)`, so nobody can claim another
    /// publisher's id.
    function createResource(bytes32 uid, uint256 price, string calldata uri) external nonReentrant returns (bytes32) {
        address owner = msg.sender;
        bytes32 resource_id = _resourceIdOf(owner, uid);
        if (resourceOwners[resource_id] != address(0)) revert AlreadyRegistered();

        // One group per resource. This contract must be the group's admin, so it
        // creates the group itself rather than accepting an id from outside.
        (bool ok, bytes memory ret) = semaphore.call(abi.encodeCall(ISemaphore.createGroup, ()));
        if (!ok || ret.length < 32) revert SemaphoreCallFailed();
        uint256 group_id = abi.decode(ret, (uint256));

        resourceOwners[resource_id] = owner;
        resourcePrice[resource_id] = price;
        resourceUris[resource_id] = uri;
        resourceGroups[resource_id] = group_id;

        emit ResourceCreated(resource_id, owner, price, group_id, uri);
        return resource_id;
    }

    function updatePrice(bytes32 resource_id, uint256 price) external {
        address owner = _ownerOrRevert(resource_id);
        if (msg.sender != owner) revert NotResourceOwner();
        resourcePrice[resource_id] = price;
        emit PriceUpdated(resource_id, owner, price);
    }

    function registerHook(bytes32 resource_id, address hook) external {
        address owner = _ownerOrRevert(resource_id);
        if (msg.sender != owner) revert NotResourceOwner();
        resourceHooks[resource_id] = hook;
        emit HookRegistered(resource_id, hook);
    }

    /// Disable (take down) a resource, or put it back.
    /// Only callable by the owner or the registry admin.
    function setDisabled(bytes32 resource_id, bool disabled) external {
        address owner = _ownerOrRevert(resource_id);
        if (msg.sender != owner && (admin == address(0) || msg.sender != admin)) revert NotResourceOwner();
        resourceDisabled[resource_id] = disabled;
        emit ResourceDisabled(resource_id, disabled, msg.sender);
    }

    /// Pay for a resource and join its group.
    /// A zero-priced resource skips the transfer entirely.
    ///
    /// The payment goes to the resource's owner as recorded here — the caller never
    /// names the recipient.
    function register(
        bytes32 resource_id,
        uint256 identity_commitment,
        address from,
        uint256 amount,
        uint256 valid_after,
        uint256 valid_before,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant {
        address owner = _ownerOrRevert(resource_id);
        _notDisabledOrRevert(resource_id);

        if (registrations[resource_id][identity_commitment]) revert AlreadyRegistered();
        if (amount != resourcePrice[resource_id]) revert IncorrectPaymentAmount();

        if (amount > 0) {
            (bool paid,) = usdc.call(
                abi.encodeWithSignature(
                    "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)",
                    from,
                    owner,
                    amount,
                    valid_after,
                    valid_before,
                    nonce,
                    v,
                    r,
                    s
                )
            );
            if (!paid) revert TransferFailed();
        }

        (bool added,) =
            semaphore.call(abi.encodeCall(ISemaphore.addMember, (resourceGroups[resource_id], identity_commitment)));
        if (!added) revert SemaphoreCallFailed();

        registrations[resource_id][identity_commitment] = true;
        emit MemberRegistered(resource_id, identity_commitment);
    }

    /// Prove membership of the resource's group without revealing which buyer you
    /// are, and record access for `stealth_address`.
    ///
    /// The proof is verified against THIS resource's group, with this resource as
    /// the scope.
    function settle(
        bytes32 resource_id,
        address stealth_address,
        uint256 merkle_tree_depth,
        uint256 merkle_tree_root,
        uint256 nullifier,
        uint256 message,
        uint256[8] calldata points,
        uint8[] calldata hook_data
    ) external nonReentrant {
        _ownerOrRevert(resource_id);
        _notDisabledOrRevert(resource_id);
        if (nullifiers[nullifier]) revert AlreadySettled();

        (bool verified,) = semaphore.call(
            abi.encodeCall(
                ISemaphore.validateProof,
                (
                    resourceGroups[resource_id],
                    ISemaphore.SemaphoreProof({
                        merkleTreeDepth: merkle_tree_depth,
                        merkleTreeRoot: merkle_tree_root,
                        nullifier: nullifier,
                        message: message,
                        scope: uint256(resource_id),
                        points: points
                    })
                )
            )
        );
        if (!verified) revert VerificationFailed();

        nullifiers[nullifier] = true;
        settlements[stealth_address][resource_id] = true;
        emit SettlementFinalized(resource_id, nullifier, message);

        address hook = resourceHooks[resource_id];
        if (hook != address(0)) {
            (bool hooked,) = hook.call(
                abi.encodeWithSignature(
                    "afterSettle(bytes32,uint256,uint256,bytes)", resource_id, nullifier, message, _toBytes(hook_data)
                )
            );
            if (!hooked) revert HookFailed();
        }
    }

    // ── Views ─────────────────────────────────────────────────────────────────

    function resourceIdFor(address publisher, bytes32 uid) external pure returns (bytes32) {
        return _resourceIdOf(publisher, uid);
    }

    function isSettled(address stealth_address, bytes32 resource_id) external view returns (bool) {
        return settlements[stealth_address][resource_id];
    }

    function isRegistered(bytes32 resource_id, uint256 identity_commitment) external view returns (bool) {
        return registrations[resource_id][identity_commitment];
    }

    function isDisabled(bytes32 resource_id) external view returns (bool) {
        return resourceDisabled[resource_id];
    }

    function getPrice(bytes32 resource_id) external view returns (uint256) {
        return resourcePrice[resource_id];
    }

    function getGroupId(bytes32 resource_id) external view returns (uint256) {
        return resourceGroups[resource_id];
    }

    function getOwner(bytes32 resource_id) external view returns (address) {
        return resourceOwners[resource_id];
    }

    function getUri(bytes32 resource_id) external view returns (string memory) {
        return resourceUris[resource_id];
    }

    function getAdmin() external view returns (address) {
        return admin;
    }

    function getUsdc() external view returns (address) {
        return usdc;
    }

    function getSemaphore() external view returns (address) {
        return semaphore;
    }

    // ── Internals ─────────────────────────────────────────────────────────────

    function _ownerOrRevert(bytes32 resource_id) private view returns (address owner) {
        owner = resourceOwners[resource_id];
        if (owner == address(0)) revert ResourceNotFound();
    }

    function _notDisabledOrRevert(bytes32 resource_id) private view {
        if (resourceDisabled[resource_id]) revert ResourceIsDisabled();
    }

    /// keccak(publisher ++ uid)
    function _resourceIdOf(address publisher, bytes32 uid) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(publisher, uid));
    }

    /// The hook takes `bytes`; `settle` takes `uint8[]`. One byte per element.
    function _toBytes(uint8[] calldata data) private pure returns (bytes memory out) {
        out = new bytes(data.length);
        for (uint256 i = 0; i < data.length; i++) {
            out[i] = bytes1(data[i]);
        }
    }
}
