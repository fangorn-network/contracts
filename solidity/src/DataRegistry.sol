// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// DataRegistry
///
/// The DataRegistry handles:
/// - network-wide publisher registration, and the protocol admin's global ban
/// - linear timeline state updates (compare-and-swap) for all multi-tenant namespaces
///
/// Namespaces are hierarchical: `app_id:publisher:subspace_id`,
/// flattened on-chain using keccak256(app_id ‖ publisher ‖ subspace_id).
///
/// A port of `stylus/data_registry`. The ABI is the same — function, error and event
/// names, argument order, and event field names — so the SDK and the workers talk to
/// either without change.
contract DataRegistry {
    uint8 internal constant STATUS_UNREGISTERED = 0;
    uint8 internal constant STATUS_ACTIVE = 1;
    uint8 internal constant STATUS_SUSPENDED = 2;

    error AlreadyRegistered();
    error NotRegistered();
    error RegistrationFeeRequired();
    error Unauthorized();
    error StaleStateRoot();
    error PublisherSuspendedErr();
    error NotRegisteredForApp();

    event PublisherRegistered(address indexed publisher, bytes32 initial_root);
    event PublisherReactivated(address indexed publisher, bytes32 current_root);
    event PublisherSuspended(address indexed publisher);
    event RegistrationFeeChanged(uint256 fee);
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
    /// Registration fee, in the native token
    uint256 public registrationFee;
    /// Number of active global publishers
    uint64 public publisherCount;
    /// The AppRegistry consulted for per-app publisher membership
    address public appRegistry;

    /// publisher => lifecycle status
    mapping(address => uint8) internal statuses;
    /// keccak256(app_id ‖ publisher ‖ subspace_id) => latest valid root
    mapping(bytes32 => bytes32) internal namespaceHeads;

    constructor(address admin_, uint256 registrationFee_, address appRegistry_) {
        admin = admin_;
        registrationFee = registrationFee_;
        appRegistry = appRegistry_;
    }

    /// Register as a new data publisher on the network.
    /// A suspended publisher cannot register their way back into Fangorn.
    function register() external payable {
        uint8 status = statuses[msg.sender];
        if (status == STATUS_ACTIVE) revert AlreadyRegistered();
        if (status == STATUS_SUSPENDED) revert PublisherSuspendedErr();
        if (msg.value < registrationFee) revert RegistrationFeeRequired();

        statuses[msg.sender] = STATUS_ACTIVE;
        publisherCount += 1;
        emit PublisherRegistered(msg.sender, bytes32(0));
    }

    /// The only graph-mutating route.
    ///
    /// Enforces linear timeline execution (compare-and-swap) over
    /// `app_id:sender:subspace_id`.
    function commitStateRoot(bytes32 app_id, bytes32 subspace_id, bytes32 old_root, bytes32 new_root) external {
        // must be an active publisher
        uint8 status = statuses[msg.sender];
        if (status == STATUS_UNREGISTERED) revert NotRegistered();
        if (status == STATUS_SUSPENDED) revert PublisherSuspendedErr();

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

    function getPublisherStatus(address publisher) external view returns (uint8) {
        return statuses[publisher];
    }

    function isRegistered(address publisher) external view returns (bool) {
        return statuses[publisher] == STATUS_ACTIVE;
    }

    function suspendPublisher(address publisher) external onlyAdmin {
        if (statuses[publisher] != STATUS_ACTIVE) revert NotRegistered();
        statuses[publisher] = STATUS_SUSPENDED;
        if (publisherCount > 0) publisherCount -= 1;
        emit PublisherSuspended(publisher);
    }

    /// Lift a network-wide suspension. Admin-only.
    /// Suspension never clears namespace heads, so every timeline resumes where it left off.
    function reinstateGlobal(address publisher) external onlyAdmin {
        if (statuses[publisher] != STATUS_SUSPENDED) revert NotRegistered();
        statuses[publisher] = STATUS_ACTIVE;
        publisherCount += 1;
        emit PublisherReactivated(publisher, bytes32(0));
    }

    function setAppRegistry(address registry) external onlyAdmin {
        appRegistry = registry;
    }

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

    /// Restore one publisher registration after a redeploy. Fill-only: it refuses a
    /// wallet this registry already knows, so it cannot lift a suspension.
    function seedPublisher(address publisher) external onlyAdmin {
        if (statuses[publisher] != STATUS_UNREGISTERED) revert AlreadyRegistered();
        statuses[publisher] = STATUS_ACTIVE;
        publisherCount += 1;
        emit PublisherRegistered(publisher, bytes32(0));
    }

    function setRegistrationFee(uint256 fee) external onlyAdmin {
        registrationFee = fee;
        emit RegistrationFeeChanged(fee);
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
