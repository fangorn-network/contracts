// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/// DataRegistry
///
/// Linear timeline state updates (compare-and-swap) for all multi-tenant namespaces.
///
/// Namespaces are hierarchical: `app_id:publisher:subspace_id`,
/// flattened on-chain using keccak256(app_id ‖ publisher ‖ subspace_id).
///
/// Only the AppRegistry writes here. Publishers commit through it
/// (`AppRegistry.commitStateRoot`), which checks that the sender may publish under the
/// app and forwards the commit with the sender's address. This contract trusts that
/// address and refuses a commit from anyone else, so who may publish is decided in one
/// place.
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

    event AdminChanged(address previousAdmin, address newAdmin);
    event StateCommitted(
        bytes32 indexed namespace_key,
        bytes32 indexed app_id,
        address indexed publisher,
        bytes32 subspace_id,
        bytes32 old_root,
        bytes32 new_root
    );

    /// Protocol admin: upgrades, and repoints the AppRegistry
    address public admin;
    /// The AppRegistry: the only address that may commit
    address public appRegistry;

    /// keccak256(app_id ‖ publisher ‖ subspace_id) => latest valid root
    mapping(bytes32 => bytes32) internal namespaceHeads;

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

    /// The only graph-mutating route, and only for the AppRegistry, which has already
    /// checked that `publisher` may publish under `app_id`.
    ///
    /// Enforces linear timeline execution (compare-and-swap) over
    /// `app_id:publisher:subspace_id`.
    function commitStateRoot(bytes32 app_id, address publisher, bytes32 subspace_id, bytes32 old_root, bytes32 new_root)
        external
    {
        if (msg.sender != appRegistry) revert Unauthorized();

        // validate linear sequence progress for this subspace only
        bytes32 key = _namespaceKey(app_id, publisher, subspace_id);
        if (namespaceHeads[key] != old_root) revert StaleStateRoot();

        namespaceHeads[key] = new_root;
        emit StateCommitted(key, app_id, publisher, subspace_id, old_root, new_root);
    }

    /// Get the latest head for a specific publisher's subspace within an application
    function getNamespaceHead(bytes32 app_id, address publisher, bytes32 subspace_id) external view returns (bytes32) {
        return namespaceHeads[_namespaceKey(app_id, publisher, subspace_id)];
    }

    /// Repoint the one writer. Until it is set, nobody can commit.
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

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Unauthorized();
        _;
    }

    /// keccak256(app_id ‖ publisher ‖ subspace_id)
    function _namespaceKey(bytes32 app_id, address publisher, bytes32 subspace_id) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(app_id, publisher, subspace_id));
    }
}
