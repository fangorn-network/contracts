// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {NonReentrant} from "./NonReentrant.sol";

/// AppRegistry
///
/// An application is a named domain and a set of agreements for associating data with
/// it. Publishers must be registered with an app to write to its namespace in the
/// DataRegistry.
///
/// An app IS a storage subscription: claiming one pulls the subscription fee (USDC),
/// and the off-chain upload gate reads `access` to decide whether to serve its
/// publishers. Membership is by invitation — the owner adds a publisher, who then
/// accepts the terms.
///
/// The DataRegistry is where the protocol admin bans a publisher network-wide, so this
/// contract asks it before letting a wallet claim an app or be added to one. The two
/// contracts therefore point at each other:
///
///   AppRegistry ── isRegistered(wallet) ──────────────▶ DataRegistry
///   AppRegistry ◀── isRegisteredForApp(app_id, sender) ── DataRegistry
///
/// A port of `stylus/app_registry`. The ABI is the same — function, error and event
/// names, argument order, and event field names — so the SDK and the workers talk to
/// either without change.
contract AppRegistry is NonReentrant {
    uint8 internal constant STATUS_UNREGISTERED = 0;
    uint8 internal constant STATUS_ACTIVE = 1;
    uint8 internal constant STATUS_SUSPENDED = 2;
    /// Added by the app owner, terms not yet accepted. Per-app only: the DataRegistry
    /// shares codes 0-2 and has no such state.
    uint8 internal constant STATUS_INVITED = 3;

    error Unauthorized();
    error AppNotFound();
    error AppAlreadyRegistered();
    error TermsNotSet();
    error TermsMismatch();
    error AlreadyRegistered();
    error NotRegistered();
    error PublisherSuspendedErr();
    error AppSuspendedErr();
    error JoinFeeRequired();
    error TransferFailed();
    error NotInvited();
    error SubscriptionFeeRequired();
    /// The wallet is not an active publisher in the DataRegistry: it never registered,
    /// or the protocol admin suspended it. Distinct from `NotRegistered`, which is
    /// about one app.
    error NotRegisteredGlobally();

    /// A new app was registered
    event AppRegistered(bytes32 indexed app_id, address indexed owner);
    /// The app's terms changed and every publisher on the old hash must accept the new
    /// terms before they can publish again
    event AppTermsChanged(bytes32 indexed app_id, bytes32 terms_hash, string terms_uri);
    event AppFeeChanged(bytes32 indexed app_id, uint256 fee);
    /// The app's agent card moved
    event AppAgentChanged(bytes32 indexed app_id, string agent_uri);
    /// A publisher joined an app AND accepted `terms_hash`
    event PublisherJoined(bytes32 indexed app_id, address indexed publisher, bytes32 terms_hash, uint256 fee);
    /// An app owner suspended a publisher from their app
    event PublisherSuspendedForApp(bytes32 indexed app_id, address indexed publisher);
    event PublisherReinstatedForApp(bytes32 indexed app_id, address indexed publisher);
    /// The protocol admin suspended (or reinstated) an entire app
    event AppSuspensionChanged(bytes32 indexed app_id, bool suspended);
    /// An app owner added a publisher, who may now accept the terms and join
    event PublisherInvited(bytes32 indexed app_id, address indexed publisher);
    /// The app's subscription was paid (at claim, or a renewal). `paid_at` is the block
    /// timestamp (Unix seconds); the off-chain gate enforces the active window.
    event AppSubscribed(bytes32 indexed app_id, address indexed payer, uint64 paid_at);
    event SubscriptionFeeChanged(uint256 fee);

    /// The app registry admin
    address public admin;
    /// ERC-20 token the subscription fee is paid in (USDC). Amounts are in its base units.
    address public usdc;
    /// Subscription fee, denominated in USDC base units (6 decimals).
    uint256 public subscriptionFee;
    /// The DataRegistry queried for network-wide publisher registration.
    address public dataRegistry;

    struct App {
        // The first three fields share one storage slot (20 + 1 + 8 bytes): keep them
        // adjacent.
        /// Zero means the app is unclaimed.
        address owner;
        /// Admin takedown flag. A suspended app is dead for every publisher at once.
        bool isAppSuspended;
        /// Block timestamp (Unix seconds) of the app's last subscription payment.
        uint64 subscribedAt;
        /// Hash of the app's current publisher terms. Zero means none are set.
        bytes32 appTerms;
        /// URI to read the terms
        string appTermsUri;
        /// Join fee, in wei. Can be zero.
        uint256 joinFee;
        /// URI of the app's ERC-8004 agent card. Empty means the app has none.
        string appAgentUri;
    }

    /// app_id => app. Internal: the getters below keep the ABI the Stylus contract has.
    mapping(bytes32 => App) internal apps;
    /// app_id => publisher => lifecycle status
    mapping(bytes32 => mapping(address => uint8)) internal statuses;
    /// app_id => publisher => the terms hash they actually accepted
    mapping(bytes32 => mapping(address => bytes32)) internal accepted;

    constructor(address admin_, address usdc_, uint256 subscriptionFee_, address dataRegistry_) {
        admin = admin_;
        usdc = usdc_;
        subscriptionFee = subscriptionFee_;
        dataRegistry = dataRegistry_;
    }

    // ── Apps ──────────────────────────────────────────────────────────────────

    /// Claim a unique app id.
    ///
    /// * `terms_hash`: the hash of the terms and conditions for using the app
    /// * `terms_uri`: where the terms can be read. NOT the app's agent card — that
    ///   goes in `setAppAgentUri`, which carries no hash precisely so that moving it
    ///   does not unregister every publisher.
    /// * `fee`: what joining the app costs a publisher, in wei
    ///
    /// The claimer becomes the app's first registered publisher.
    ///
    /// Claiming pays the subscription fee (USDC), so an app cannot exist unpaid. The
    /// caller must `approve` this contract for `subscriptionFee()` first.
    ///
    /// The caller must be a registered publisher in the DataRegistry, so a wallet the
    /// protocol admin has banned cannot come back as an app owner.
    function registerApp(bytes32 app_id, bytes32 terms_hash, string calldata terms_uri, uint256 fee)
        external
        nonReentrant
    {
        App storage app = apps[app_id];
        if (app.owner != address(0)) revert AppAlreadyRegistered();
        address owner = msg.sender;
        if (!_isRegisteredGlobally(owner)) revert NotRegisteredGlobally();
        _paySubscription(app_id, owner);

        app.owner = owner;
        app.appTerms = terms_hash;
        app.appTermsUri = terms_uri;
        app.joinFee = fee;
        _joinOwner(app_id, owner, terms_hash);

        emit AppRegistered(app_id, owner);
        emit AppTermsChanged(app_id, terms_hash, terms_uri);
        emit AppFeeChanged(app_id, fee);
    }

    function getAppOwner(bytes32 app_id) external view returns (address) {
        return apps[app_id].owner;
    }

    /// Renew an app's subscription: pays the fee again and re-stamps `now`.
    /// Only callable by the app owner. Renewing while still active is allowed.
    function renewApp(bytes32 app_id) external nonReentrant onlyAppOwner(app_id) {
        _paySubscription(app_id, apps[app_id].owner);
    }

    /// Publish (or update) an app's publisher agreement. Only callable by the app owner.
    ///
    /// Danger: every publisher who accepted the previous terms becomes unregistered
    /// until they accept the new ones.
    function setAppTerms(bytes32 app_id, bytes32 terms_hash, string calldata terms_uri)
        external
        onlyAppOwner(app_id)
    {
        App storage app = apps[app_id];
        app.appTerms = terms_hash;
        app.appTermsUri = terms_uri;
        // The owner accepts their own terms by publishing them. Without this they are
        // locked out of their own app by every edit.
        _joinOwner(app_id, app.owner, terms_hash);
        emit AppTermsChanged(app_id, terms_hash, terms_uri);
    }

    /// Set the app's join fee in wei
    function setAppFee(bytes32 app_id, uint256 fee) external onlyAppOwner(app_id) {
        apps[app_id].joinFee = fee;
        emit AppFeeChanged(app_id, fee);
    }

    /// Point at the app's ERC-8004 agent card. Only callable by the app owner.
    function setAppAgentUri(bytes32 app_id, string calldata agent_uri) external onlyAppOwner(app_id) {
        apps[app_id].appAgentUri = agent_uri;
        emit AppAgentChanged(app_id, agent_uri);
    }

    /// Suspend an app's entire set of publishers. Admin-only global takedown.
    /// Memberships are left intact so a reinstatement restores them exactly.
    function suspendApp(bytes32 app_id) external {
        _setAppSuspended(app_id, true);
    }

    /// Reinstate a suspended app
    function reinstateApp(bytes32 app_id) external {
        _setAppSuspended(app_id, false);
    }

    // ── Membership ────────────────────────────────────────────────────────────

    /// Add a publisher to this app. Only callable by the app owner.
    ///
    /// This is an invitation, not a membership: the publisher still has to accept the
    /// terms (and pay the join fee) with `registerForApp`. Nobody can join uninvited.
    /// Take an invitation back with `suspendForApp`.
    ///
    /// The publisher must be registered in the DataRegistry: an owner cannot bring in
    /// a wallet that never registered, or one the protocol admin has banned.
    function addPublisher(bytes32 app_id, address publisher) external onlyAppOwner(app_id) {
        if (!_isRegisteredGlobally(publisher)) revert NotRegisteredGlobally();
        if (statuses[app_id][publisher] != STATUS_UNREGISTERED) revert AlreadyRegistered();
        statuses[app_id][publisher] = STATUS_INVITED;
        emit PublisherInvited(app_id, publisher);
    }

    /// Register to publish to an app. By registering, you are agreeing to the app's
    /// terms and conditions. The app owner must have added you first (`addPublisher`).
    function registerForApp(bytes32 app_id, bytes32 terms_hash) external payable nonReentrant {
        App storage app = apps[app_id];
        address owner = app.owner;
        if (owner == address(0)) revert AppNotFound();
        if (app.isAppSuspended) revert AppSuspendedErr();

        // empty terms are invalid
        bytes32 current = app.appTerms;
        if (current == bytes32(0)) revert TermsNotSet();
        if (terms_hash != current) revert TermsMismatch();

        uint8 status = statuses[app_id][msg.sender];
        // must have been added by the app owner
        if (status == STATUS_UNREGISTERED) revert NotInvited();
        // must not be suspended as a publisher
        if (status == STATUS_SUSPENDED) revert PublisherSuspendedErr();
        if (status == STATUS_ACTIVE && accepted[app_id][msg.sender] == current) revert AlreadyRegistered();

        // do not charge the join fee when accepting new publishing terms
        uint256 fee = status == STATUS_ACTIVE ? 0 : app.joinFee;
        if (msg.value < fee) revert JoinFeeRequired();

        statuses[app_id][msg.sender] = STATUS_ACTIVE;
        accepted[app_id][msg.sender] = current;

        // paid directly to the app owner
        if (msg.value != 0) _sendEth(owner, msg.value);

        emit PublisherJoined(app_id, msg.sender, current, fee);
    }

    /// Suspend a publisher from only this app. Does not suspend globally.
    function suspendForApp(bytes32 app_id, address publisher) external onlyAppOwner(app_id) {
        if (statuses[app_id][publisher] == STATUS_UNREGISTERED) revert NotRegistered();
        statuses[app_id][publisher] = STATUS_SUSPENDED;
        emit PublisherSuspendedForApp(app_id, publisher);
    }

    /// Unsuspend a publisher from the app
    function reinstateForApp(bytes32 app_id, address publisher) external onlyAppOwner(app_id) {
        if (statuses[app_id][publisher] != STATUS_SUSPENDED) revert NotRegistered();
        statuses[app_id][publisher] = STATUS_ACTIVE;
        emit PublisherReinstatedForApp(app_id, publisher);
    }

    // ── Views ─────────────────────────────────────────────────────────────────

    function appTerms(bytes32 app_id) external view returns (bytes32) {
        return apps[app_id].appTerms;
    }

    function appTermsUri(bytes32 app_id) external view returns (string memory) {
        return apps[app_id].appTermsUri;
    }

    function appFee(bytes32 app_id) external view returns (uint256) {
        return apps[app_id].joinFee;
    }

    function appAgentUri(bytes32 app_id) external view returns (string memory) {
        return apps[app_id].appAgentUri;
    }

    function isAppSuspended(bytes32 app_id) external view returns (bool) {
        return apps[app_id].isAppSuspended;
    }

    function subscribedAt(bytes32 app_id) external view returns (uint64) {
        return apps[app_id].subscribedAt;
    }

    /// Is a publisher actively registered in an app? False if the publisher is
    /// suspended, merely invited, on stale terms, or the app is suspended.
    function isRegisteredForApp(bytes32 app_id, address publisher) public view returns (bool) {
        App storage app = apps[app_id];
        bytes32 current = app.appTerms;
        return !app.isAppSuspended && current != bytes32(0) && statuses[app_id][publisher] == STATUS_ACTIVE
            && accepted[app_id][publisher] == current;
    }

    /// The single oracle the upload gate reads: `(registered, owner, paid_at)`.
    /// `registered` is `isRegisteredForApp`; `owner` is zero for an unclaimed app;
    /// `paid_at` is the app's last subscription timestamp. The gate applies its own
    /// active-window policy off-chain.
    function access(bytes32 app_id, address publisher) external view returns (bool, address, uint64) {
        App storage app = apps[app_id];
        return (isRegisteredForApp(app_id, publisher), app.owner, app.subscribedAt);
    }

    /// An address's status in an app
    function statusForApp(bytes32 app_id, address publisher) external view returns (uint8) {
        return statuses[app_id][publisher];
    }

    function acceptedTerms(bytes32 app_id, address publisher) external view returns (bytes32) {
        return accepted[app_id][publisher];
    }

    /// `(terms_hash, terms_uri, join_fee, status, registered)` — a join screen in one call
    function joinInfo(bytes32 app_id, address publisher)
        external
        view
        returns (bytes32, string memory, uint256, uint8, bool)
    {
        App storage app = apps[app_id];
        return (
            app.appTerms,
            app.appTermsUri,
            app.joinFee,
            statuses[app_id][publisher],
            isRegisteredForApp(app_id, publisher)
        );
    }

    // ── Protocol admin ────────────────────────────────────────────────────────

    function setSubscriptionFee(uint256 fee) external onlyAdmin {
        subscriptionFee = fee;
        emit SubscriptionFeeChanged(fee);
    }

    /// Update the fee token address (USDC).
    function setUsdc(address token) external onlyAdmin {
        usdc = token;
    }

    /// Update the DataRegistry used for the registration check. Until one is set,
    /// nobody reads as registered, so no app can be claimed and nobody added.
    function setDataRegistry(address registry) external onlyAdmin {
        dataRegistry = registry;
    }

    /// Recreate an app for its original owner after a redeploy. Fill-only: it refuses
    /// an app id that is already claimed.
    ///
    /// Testnet migration aid: it pulls no subscription fee and stamps the app as paid
    /// now. It does not ask the DataRegistry about `owner` either — the admin is the
    /// ban authority, and an owner banned after claiming keeps their app anyway.
    function seedApp(
        bytes32 app_id,
        address owner,
        bytes32 terms_hash,
        string calldata terms_uri,
        uint256 fee,
        string calldata agent_uri
    ) external onlyAdmin {
        App storage app = apps[app_id];
        if (app.owner != address(0)) revert AppAlreadyRegistered();
        // a zero owner would read as unclaimed
        if (owner == address(0)) revert AppNotFound();

        app.owner = owner;
        app.appTerms = terms_hash;
        app.appTermsUri = terms_uri;
        app.joinFee = fee;
        _joinOwner(app_id, owner, terms_hash);

        emit AppRegistered(app_id, owner);
        emit AppTermsChanged(app_id, terms_hash, terms_uri);
        emit AppFeeChanged(app_id, fee);
        if (bytes(agent_uri).length != 0) {
            app.appAgentUri = agent_uri;
            emit AppAgentChanged(app_id, agent_uri);
        }
        _stampPaid(app_id, owner);
    }

    /// Restore one membership after a redeploy: the publisher's status in the app and
    /// the terms hash they accepted, verbatim. Fill-only: it refuses a publisher the
    /// app already knows, so it cannot rewrite a live membership.
    function seedPublisherForApp(bytes32 app_id, address publisher, uint8 status, bytes32 accepted_terms)
        external
        onlyAdmin
    {
        if (apps[app_id].owner == address(0)) revert AppNotFound();
        if (statuses[app_id][publisher] != STATUS_UNREGISTERED) revert AlreadyRegistered();
        statuses[app_id][publisher] = status;
        accepted[app_id][publisher] = accepted_terms;
        // Either event keeps the pair findable in the logs for the next migration.
        if (status == STATUS_ACTIVE) {
            emit PublisherJoined(app_id, publisher, accepted_terms, 0);
        } else {
            emit PublisherInvited(app_id, publisher);
        }
    }

    /// Sweep `amount` of collected USDC to `to`.
    function withdrawUsdc(address to, uint256 amount) external nonReentrant onlyAdmin {
        if (!_tokenCall(abi.encodeWithSignature("transfer(address,uint256)", to, amount))) revert TransferFailed();
    }

    /// Rescue native ETH held by the contract.
    function withdrawEth(address to, uint256 amount) external nonReentrant onlyAdmin {
        _sendEth(to, amount);
    }

    // ── Internals ─────────────────────────────────────────────────────────────

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Unauthorized();
        _;
    }

    modifier onlyAppOwner(bytes32 app_id) {
        address owner = apps[app_id].owner;
        if (owner == address(0)) revert AppNotFound();
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    function _setAppSuspended(bytes32 app_id, bool suspended) private onlyAdmin {
        App storage app = apps[app_id];
        if (app.owner == address(0)) revert AppNotFound();
        app.isAppSuspended = suspended;
        emit AppSuspensionChanged(app_id, suspended);
    }

    /// Mark an app owner as an active publisher of their own app
    function _joinOwner(bytes32 app_id, address owner, bytes32 terms_hash) private {
        statuses[app_id][owner] = STATUS_ACTIVE;
        accepted[app_id][owner] = terms_hash;
    }

    /// Pull the subscription fee from `payer` and stamp the app as paid now.
    function _paySubscription(bytes32 app_id, address payer) private {
        uint256 fee = subscriptionFee;
        if (
            fee != 0
                && !_tokenCall(abi.encodeWithSignature("transferFrom(address,address,uint256)", payer, address(this), fee))
        ) revert SubscriptionFeeRequired();
        _stampPaid(app_id, payer);
    }

    /// Stamp the app's subscription as paid now.
    function _stampPaid(bytes32 app_id, address payer) private {
        uint64 paidAt = uint64(block.timestamp);
        apps[app_id].subscribedAt = paidAt;
        emit AppSubscribed(app_id, payer, paidAt);
    }

    /// Call the fee token and require a clean `true` back. A revert, no contract at
    /// the address, or anything other than `true` is a failure.
    function _tokenCall(bytes memory data) private returns (bool) {
        (bool ok, bytes memory ret) = usdc.call(data);
        return ok && ret.length == 32 && abi.decode(ret, (uint256)) == 1;
    }

    function _sendEth(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// Cross-contract check: is `who` an active registered publisher in the
    /// DataRegistry? Anything but a clean `true` — a revert, no contract at the
    /// address, a malformed return — counts as no, so an unwired registry fails
    /// closed. A plain interface call would revert on the last two instead.
    function _isRegisteredGlobally(address who) private view returns (bool) {
        (bool ok, bytes memory ret) = dataRegistry.staticcall(abi.encodeWithSignature("isRegistered(address)", who));
        return ok && ret.length == 32 && abi.decode(ret, (uint256)) == 1;
    }
}
