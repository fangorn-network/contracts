// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// AppRegistry
///
/// Names apps. An app is a curator's repo of citations in the DataRegistry; this
/// contract maps a short id to that repo, to the address paid when the app refers a
/// sale, and to the app's ERC-8004 agent card. It decides nothing about data.
///
/// Registering is free. An app can be renamed (`renameApp`): the new id becomes an
/// alias of the id it was registered under, every function that takes an app id
/// accepts any of them, and ids an app has gone by stay its own.
///
/// Deployed behind an ERC-1967 proxy (UUPS). Storage is append-only: add state after
/// the last variable and fields at the end of `App`, and never reorder, retype or
/// remove what is there.
contract AppRegistry is Initializable, UUPSUpgradeable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// Retired. Kept for the storage layout of `statuses`.
    enum Status {
        None,
        Active,
        Suspended
    }

    /// Retired: each app was an ERC-721 token. Kept for the storage layout.
    /// @custom:storage-location erc7201:openzeppelin.storage.ERC721
    struct ERC721Storage {
        string _name;
        string _symbol;
        mapping(uint256 tokenId => address) _owners;
        mapping(address owner => uint256) _balances;
        mapping(uint256 tokenId => address) _tokenApprovals;
        mapping(address owner => mapping(address operator => bool)) _operatorApprovals;
    }

    /// Not the admin, for an admin function; not the app's owner, for an owner function.
    error Unauthorized();
    error TransferFailed();
    error AppNotFound();
    error AppAlreadyRegistered();
    error ZeroAppId();

    event AppRegistered(bytes32 indexed app_id, address indexed owner);
    /// `app_id` is the canonical id; `new_id` the one it goes by from now on.
    event AppRenamed(bytes32 indexed app_id, bytes32 indexed new_id);
    event AppAgentChanged(bytes32 indexed app_id, string agent_uri);
    event AppSuspensionChanged(bytes32 indexed app_id, bool suspended);
    event CuratorChanged(bytes32 indexed app_id, address indexed curator, string repo);
    event PayoutChanged(bytes32 indexed app_id, address payout);
    event DataRegistryChanged(address previous_registry, address new_registry);
    event TokenWithdrawn(address indexed token, address indexed to, uint256 amount);
    /// Zero renounces the admin role, and upgrades, for good.
    event AdminChanged(address previous_admin, address new_admin);

    address public admin;
    /// Retired.
    uint64 internal subscriptionPeriod;
    /// Retired.
    address internal usdc;
    /// Retired.
    uint256 internal subscriptionFee;
    /// The DataRegistry the apps' curator repos live in.
    address public dataRegistry;

    struct App {
        /// Zero means unregistered.
        address owner;
        /// Admin takedown flag.
        bool isAppSuspended;
        /// Retired.
        uint64 expiry;
        string appAgentUri;
        /// Paid when the app refers a sale. Zero means the owner.
        address payout;
        /// The app's repo is (curator, repo) in the DataRegistry. A zero curator means
        /// the owner.
        address curator;
        string repo;
    }

    mapping(bytes32 => App) internal apps;
    /// Retired.
    /// @custom:oz-renamed-from statusForApp
    mapping(bytes32 => mapping(address => Status)) internal statuses;
    /// Retired.
    mapping(address => bool) internal globalSuspensions;
    /// Retired.
    /// @custom:oz-renamed-from exclusionCount
    mapping(bytes32 => mapping(bytes32 => uint64)) internal exclusions;

    /// Every registered app id, oldest first.
    bytes32[] internal appIds;
    /// owner => owned apps, oldest first.
    mapping(address => bytes32[]) internal appIdsOf;
    /// alias => canonical id. Zero for an id that is no alias.
    mapping(bytes32 => bytes32) internal canonicalOf;
    /// canonical id => the id it was last renamed to. Zero if never renamed.
    mapping(bytes32 => bytes32) internal renamedTo;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin_) external initializer {
        admin = admin_;
    }

    // ── Apps ──────────────────────────────────────────────────────────────────

    /// Register `app_id`, owned by the caller.
    function registerApp(bytes32 app_id) external {
        if (app_id == bytes32(0)) revert ZeroAppId();
        if (apps[app_id].owner != address(0) || canonicalOf[app_id] != bytes32(0)) revert AppAlreadyRegistered();
        apps[app_id].owner = msg.sender;
        appIds.push(app_id);
        appIdsOf[msg.sender].push(app_id);
        emit AppRegistered(app_id, msg.sender);
    }

    function getAppOwner(bytes32 app_id) external view returns (address) {
        return apps[_canonical(app_id)].owner;
    }

    /// Give the app a new id. Owner only. `new_id` must be unclaimed, or an id this app
    /// already goes by.
    function renameApp(bytes32 app_id, bytes32 new_id) external {
        app_id = _onlyAppOwner(app_id);
        if (new_id == bytes32(0)) revert ZeroAppId();
        bytes32 holder = _canonical(new_id);
        if (holder != app_id) {
            if (apps[holder].owner != address(0)) revert AppAlreadyRegistered();
            canonicalOf[new_id] = app_id;
        }
        renamedTo[app_id] = new_id;
        emit AppRenamed(app_id, new_id);
    }

    /// The id `app_id`'s app was registered under. Any other id comes back unchanged.
    function canonicalAppId(bytes32 app_id) external view returns (bytes32) {
        return _canonical(app_id);
    }

    /// The id `app_id`'s app currently goes by. Any other id comes back unchanged.
    function currentAppId(bytes32 app_id) external view returns (bytes32) {
        app_id = _canonical(app_id);
        bytes32 current = renamedTo[app_id];
        return current == bytes32(0) ? app_id : current;
    }

    function appCount() external view returns (uint256) {
        return appIds.length;
    }

    /// Canonical ids, oldest first. Includes suspended apps.
    function appsPage(uint256 offset, uint256 limit) external view returns (bytes32[] memory page) {
        uint256 left = offset < appIds.length ? appIds.length - offset : 0;
        page = new bytes32[](limit < left ? limit : left);
        for (uint256 i = 0; i < page.length; i++) {
            page[i] = appIds[offset + i];
        }
    }

    function appsOf(address owner) external view returns (bytes32[] memory) {
        return appIdsOf[owner];
    }

    /// Owner only.
    function setAppAgentUri(bytes32 app_id, string calldata agent_uri) external {
        app_id = _onlyAppOwner(app_id);
        apps[app_id].appAgentUri = agent_uri;
        emit AppAgentChanged(app_id, agent_uri);
    }

    function appAgentUri(bytes32 app_id) external view returns (string memory) {
        return apps[_canonical(app_id)].appAgentUri;
    }

    /// Point the app at its repo, `(curator, repo)` in the DataRegistry. Owner only.
    function setCurator(bytes32 app_id, address curator, string calldata repo) external {
        app_id = _onlyAppOwner(app_id);
        App storage app = apps[app_id];
        app.curator = curator;
        app.repo = repo;
        emit CuratorChanged(app_id, curator, repo);
    }

    function curatorOf(bytes32 app_id) external view returns (address curator, string memory repo) {
        App storage app = apps[_canonical(app_id)];
        curator = app.curator == address(0) ? app.owner : app.curator;
        repo = app.repo;
    }

    /// Owner only. Zero pays the owner.
    function setPayout(bytes32 app_id, address payout) external {
        app_id = _onlyAppOwner(app_id);
        apps[app_id].payout = payout;
        emit PayoutChanged(app_id, payout);
    }

    function payoutOf(bytes32 app_id) external view returns (address) {
        App storage app = apps[_canonical(app_id)];
        return app.payout == address(0) ? app.owner : app.payout;
    }

    function isAppSuspended(bytes32 app_id) external view returns (bool) {
        return apps[_canonical(app_id)].isAppSuspended;
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    function setAdmin(address new_admin) external onlyAdmin {
        emit AdminChanged(admin, new_admin);
        admin = new_admin;
    }

    function _authorizeUpgrade(address) internal override onlyAdmin {}

    function setDataRegistry(address registry) external onlyAdmin {
        emit DataRegistryChanged(dataRegistry, registry);
        dataRegistry = registry;
    }

    /// Take an app's name down (`true`), or put it back.
    function setAppSuspended(bytes32 app_id, bool is_suspended) external onlyAdmin {
        app_id = _canonical(app_id);
        if (apps[app_id].owner == address(0)) revert AppNotFound();
        apps[app_id].isAppSuspended = is_suspended;
        emit AppSuspensionChanged(app_id, is_suspended);
    }

    /// Send out an ERC-20 the contract holds.
    function withdrawToken(address token, address to, uint256 amount) external nonReentrant onlyAdmin {
        if (!IERC20(token).trySafeTransfer(to, amount)) revert TransferFailed();
        emit TokenWithdrawn(token, to, amount);
    }

    // ── Internals ─────────────────────────────────────────────────────────────

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Unauthorized();
        _;
    }

    function _onlyAppOwner(bytes32 app_id) private view returns (bytes32) {
        app_id = _canonical(app_id);
        address owner = apps[app_id].owner;
        if (owner == address(0)) revert AppNotFound();
        if (msg.sender != owner) revert Unauthorized();
        return app_id;
    }

    function _canonical(bytes32 app_id) private view returns (bytes32) {
        bytes32 canonical = canonicalOf[app_id];
        return canonical == bytes32(0) ? app_id : canonical;
    }
}
