// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/// DataRegistry
///
/// The DataRegistry handles:
/// - the protocol admin's network-wide ban: a map of suspended wallets
/// - linear timeline state updates (compare-and-swap) for all multi-tenant namespaces
///
/// Namespaces are hierarchical: `app_id:publisher:subspace_id`,
/// flattened on-chain using keccak256(app_id ‖ publisher ‖ subspace_id).
///
/// There is no publisher registration: a wallet publishes once it belongs to an app,
/// which `commitStateRoot` asks the AppRegistry on every commit. The AppRegistry in
/// turn reads `suspended` before it lets a wallet claim an app or be added to one.
///
/// Deployed behind an ERC-1967 proxy (UUPS): the proxy holds the state and the address,
/// and the admin can point it at a new implementation. Storage is therefore
/// append-only: add state variables after the last one, and never reorder, retype or
/// remove what is there. A new version is an edit to this file; the upgrade tooling
/// checks its storage against the build of the live version, committed under
/// `deployed/`.
contract DataRegistry is Initializable, UUPSUpgradeable {
    error Unauthorized();
    error StaleStateRoot();
    error PublisherSuspendedErr();
    error NotRegisteredForApp();

    event PublisherReactivated(address indexed publisher, bytes32 current_root);
    event PublisherSuspended(address indexed publisher);
    event AdminChanged(address previousAdmin, address newAdmin);
    event StateCommitted(
        bytes32 indexed namespace_key,
        bytes32 indexed app_id,
        address indexed publisher,
        bytes32 subspace_id,
        bytes32 old_root,
        bytes32 new_root
    );

    /// Protocol admin (has global takedown authority)
    address public admin;
    /// Left over from publisher registration, which an earlier version had, like
    /// `publisherCount` and `statuses` below. Nothing reads or writes them, but they
    /// stay declared: removing one would move every slot after it, and
    /// `publisherCount` shares its slot with `appRegistry`.
    uint256 private registrationFee;
    uint64 private publisherCount;
    /// The AppRegistry consulted for per-app publisher membership
    address public appRegistry;

    mapping(address => uint8) private statuses;
    /// keccak256(app_id ‖ publisher ‖ subspace_id) => latest valid root
    mapping(bytes32 => bytes32) internal namespaceHeads;
    /// wallet => banned network-wide by the protocol admin
    mapping(address => bool) public suspended;

    /// The implementation is only ever used through a proxy. Lock it, so nobody can
    /// initialize it directly.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// Takes the place of a constructor: runs once, in the proxy's storage, as part of
    /// the proxy's deployment.
    function initialize(address admin_, address appRegistry_) external initializer {
        admin = admin_;
        appRegistry = appRegistry_;
    }

    /// The only graph-mutating route.
    ///
    /// Enforces linear timeline execution (compare-and-swap) over
    /// `app_id:sender:subspace_id`.
    function commitStateRoot(bytes32 app_id, bytes32 subspace_id, bytes32 old_root, bytes32 new_root) external {
        if (suspended[msg.sender]) revert PublisherSuspendedErr();

        // fail if not an active publisher in the app registry for the given app
        if (!_isRegisteredForApp(app_id, msg.sender)) revert NotRegisteredForApp();

        // validate linear sequence progress for this subspace only
        bytes32 key = _namespaceKey(app_id, msg.sender, subspace_id);
        if (namespaceHeads[key] != old_root) revert StaleStateRoot();

        namespaceHeads[key] = new_root;
        emit StateCommitted(key, app_id, msg.sender, subspace_id, old_root, new_root);
    }

    /// Get the latest head for a specific publisher's subspace within an application
    function getNamespaceHead(bytes32 app_id, address publisher, bytes32 subspace_id) external view returns (bytes32) {
        return namespaceHeads[_namespaceKey(app_id, publisher, subspace_id)];
    }

    /// Ban a wallet network-wide. Admin-only. Any address can be banned, including one
    /// that has never published.
    function suspendPublisher(address publisher) external onlyAdmin {
        suspended[publisher] = true;
        emit PublisherSuspended(publisher);
    }

    /// Lift a network-wide suspension. Admin-only.
    /// Suspension never clears namespace heads, so every timeline resumes where it left off.
    function reinstateGlobal(address publisher) external onlyAdmin {
        suspended[publisher] = false;
        emit PublisherReactivated(publisher, bytes32(0));
    }

    function setAppRegistry(address registry) external onlyAdmin {
        appRegistry = registry;
    }

    /// Hand the admin role to another address. The admin is also who may upgrade this
    /// contract, so setting zero renounces both for good.
    function setAdmin(address new_admin) external onlyAdmin {
        emit AdminChanged(admin, new_admin);
        admin = new_admin;
    }

    /// Only the admin may point the proxy at a new implementation.
    function _authorizeUpgrade(address) internal override onlyAdmin {}

    /// Restore one namespace head after a redeploy. Fill-only: it refuses a slot that
    /// already holds a root, so it cannot rewrite a live timeline.
    function seedNamespaceHead(bytes32 app_id, address publisher, bytes32 subspace_id, bytes32 root)
        external
        onlyAdmin
    {
        bytes32 key = _namespaceKey(app_id, publisher, subspace_id);
        if (namespaceHeads[key] != bytes32(0)) revert StaleStateRoot();
        namespaceHeads[key] = root;
        emit StateCommitted(key, app_id, publisher, subspace_id, bytes32(0), root);
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Unauthorized();
        _;
    }

    /// keccak256(app_id ‖ publisher ‖ subspace_id)
    function _namespaceKey(bytes32 app_id, address publisher, bytes32 subspace_id) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(app_id, publisher, subspace_id));
    }

    /// Cross-contract check: is `publisher` an active publisher of `app_id`? Anything
    /// but a clean `true` — a revert, no contract at the address, a malformed return —
    /// counts as no. A plain interface call would revert on the last two instead.
    function _isRegisteredForApp(bytes32 app_id, address publisher) private view returns (bool) {
        (bool ok, bytes memory ret) =
            appRegistry.staticcall(abi.encodeWithSignature("isRegisteredForApp(bytes32,address)", app_id, publisher));
        return ok && ret.length == 32 && abi.decode(ret, (uint256)) == 1;
    }
}
