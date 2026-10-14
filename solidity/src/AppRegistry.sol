// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {IERC5643} from "./IERC5643.sol";

/// The DataRegistry's one write, which accepts calls from this contract only.
interface IDataRegistry {
    function commitStateRoot(bytes32 app_id, address publisher, bytes32 subspace_id, bytes32 old_root, bytes32 new_root)
        external;
}

/// AppRegistry
///
/// An application is a named domain and a set of agreements for associating data with
/// it. Publishers must be registered with an app to write to its namespace in the
/// DataRegistry.
///
/// An app IS a storage subscription: claiming one pulls the subscription fee (USDC)
/// for one period, and the off-chain upload gate reads `access` to decide whether to
/// serve its publishers. Membership is by invitation — the owner adds a publisher, who
/// then accepts the terms.
///
/// Each app is also an ERC-721 token, id `uint256(app_id)`, minted to its owner at
/// claim, and its subscription follows ERC-5643: `expiresAt`, `isRenewable`,
/// `renewSubscription` and `cancelSubscription`. The token cannot be transferred.
///
/// Every commit goes through this contract (`commitStateRoot`). It checks that the
/// sender may publish under the app — the protocol admin's network-wide ban is kept
/// here too — and forwards the commit to the DataRegistry, which accepts commits from
/// this contract alone.
///
/// Deployed behind an ERC-1967 proxy (UUPS): the proxy holds the state and the address,
/// and the admin can point it at a new implementation. Storage is therefore
/// append-only: add state variables after the last one and fields at the end of
/// `App`, and never reorder, retype or remove what is there. A new version is an edit
/// to this file; the upgrade tooling checks its storage against the build of the live
/// version, committed under `deployed/`.
contract AppRegistry is Initializable, UUPSUpgradeable, ERC721Upgradeable, ReentrancyGuardTransient, IERC5643 {
    /// A publisher's standing in one app. In the ABI it is a uint8, in this order.
    enum Status {
        Unregistered,
        Active,
        Suspended,
        /// Added by the app owner, terms not yet accepted.
        Invited
    }

    error Unauthorized();
    error AppNotFound();
    error AppAlreadyRegistered();
    /// Claiming or setting terms: the terms hash is zero. An app always has terms, so
    /// that there is something to accept.
    error TermsNotSet();
    /// Joining: not the app's current terms. Committing: the terms the publisher
    /// accepted are no longer the app's; accept the new ones with `registerForApp`.
    error TermsMismatch();
    error AlreadyRegistered();
    /// `reinstateForApp`: the publisher is not suspended from this app
    error PublisherNotSuspended();
    /// The protocol admin has suspended the publisher network-wide (`setGlobalSuspension`)
    error PublisherSuspendedGlobal();
    /// The app's owner has suspended the publisher from this app (`suspendForApp`)
    error PublisherSuspendedApp();
    /// The protocol admin has taken the app down (`setAppSuspended`)
    error AppSuspended();
    /// `msg.value` is not the join fee: exactly the app's fee to join, zero to accept
    /// new terms
    error JoinFeeMismatch();
    error TransferFailed();
    error NotInvited();
    error SubscriptionFeeRequired();
    /// An app's token cannot be transferred or burned
    error NotTransferable();
    /// The subscription has a period or more left; renew it once less than that remains
    error SubscriptionNotRenewable();
    /// `renewSubscription`: `duration` is not the subscription period
    error DurationMismatch();
    /// The subscription is paid in USDC; renewing or cancelling takes no ETH
    error EthNotAccepted();
    /// The subscription period cannot be zero
    error ZeroPeriod();
    /// Committing: invited, but has not joined (`registerForApp`)
    error NotRegisteredForApp();
    /// Raised by the DataRegistry and passed through by `commitStateRoot`: `old_root` is
    /// not the current head. Declared here so it is in this contract's ABI.
    error StaleStateRoot();

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
    /// The protocol admin banned a wallet network-wide, or lifted the ban
    event GlobalSuspensionChanged(address indexed publisher, bool suspended);
    /// The protocol admin suspended (or reinstated) an entire app
    event AppSuspensionChanged(bytes32 indexed app_id, bool suspended);
    /// An app owner added a publisher, who may now accept the terms and join
    event PublisherInvited(bytes32 indexed app_id, address indexed publisher);
    event SubscriptionFeeChanged(uint256 fee);
    /// The admin changed the period: it applies from each app's next payment
    event SubscriptionPeriodChanged(uint64 period);
    event AdminChanged(address previousAdmin, address newAdmin);

    /// The app registry admin
    address public admin;
    /// How long one subscription payment lasts, in seconds. Shares a slot with `admin`.
    uint64 public subscriptionPeriod;
    /// ERC-20 token the subscription fee is paid in (USDC). Amounts are in its base units.
    address public usdc;
    /// Subscription fee, denominated in USDC base units (6 decimals).
    uint256 public subscriptionFee;
    /// The DataRegistry that commits are forwarded to
    address public dataRegistry;

    struct App {
        // The first three fields share one storage slot (20 + 1 + 8 bytes): keep them
        // adjacent.
        /// Zero means the app is unclaimed.
        address owner;
        /// Admin takedown flag. A suspended app is dead for every publisher at once.
        bool isAppSuspended;
        /// When the subscription expires (Unix seconds). Zero once cancelled.
        uint64 expiry;
        /// Hash of the app's current publisher terms. Zero means none are set.
        bytes32 appTerms;
        /// URI to read the terms
        string appTermsUri;
        /// Join fee, in wei. Can be zero.
        uint256 joinFee;
        /// URI of the app's ERC-8004 agent card. Empty means the app has none.
        string appAgentUri;
    }

    /// app_id => app. Internal: the getters below are the ABI the SDK reads.
    mapping(bytes32 => App) internal apps;
    /// app_id => publisher => standing in the app
    mapping(bytes32 => mapping(address => Status)) public statusForApp;
    /// app_id => publisher => the terms hash they actually accepted
    mapping(bytes32 => mapping(address => bytes32)) public acceptedTerms;
    /// wallet => banned network-wide by the protocol admin
    mapping(address => bool) public globalSuspensions;

    /// The implementation is only ever used through a proxy. Lock it, so nobody can
    /// initialize it directly.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// Takes the place of a constructor: runs once, in the proxy's storage, as part of
    /// the proxy's deployment.
    function initialize(address admin_, address usdc_, uint256 subscriptionFee_, uint64 subscriptionPeriod_)
        external
        initializer
    {
        __ERC721_init("FAPP", "FAPP");
        admin = admin_;
        usdc = usdc_;
        subscriptionFee = subscriptionFee_;
        _setSubscriptionPeriod(subscriptionPeriod_);
    }

    // ── Apps ──────────────────────────────────────────────────────────────────

    /// Claim a unique app id.
    ///
    /// * `terms_hash`: the hash of the terms and conditions for using the app. Not zero.
    /// * `terms_uri`: where the terms can be read. NOT the app's agent card — that
    ///   goes in `setAppAgentUri`, which carries no hash precisely so that moving it
    ///   does not unregister every publisher.
    /// * `fee`: what joining the app costs a publisher, in wei
    ///
    /// The claimer becomes the app's first registered publisher.
    ///
    /// Claiming pays the subscription fee (USDC) for one period, so an app cannot exist
    /// unpaid. The caller must `approve` this contract for `subscriptionFee()` first.
    /// It mints the app's token to the claimer.
    ///
    /// The caller must not be banned network-wide (`globalSuspensions`), so a wallet the
    /// protocol admin has banned cannot come back as an app owner.
    function registerApp(bytes32 app_id, bytes32 terms_hash, string calldata terms_uri, uint256 fee)
        external
        nonReentrant
    {
        App storage app = apps[app_id];
        address owner = msg.sender;
        if (globalSuspensions[owner]) revert PublisherSuspendedGlobal();
        if (app.owner != address(0)) revert AppAlreadyRegistered();
        if (terms_hash == bytes32(0)) revert TermsNotSet();
        _paySubscription(app_id, owner);

        app.owner = owner;
        app.appTerms = terms_hash;
        app.appTermsUri = terms_uri;
        app.joinFee = fee;
        _joinOwner(app_id, owner, terms_hash);
        _mint(owner, uint256(app_id));

        emit AppRegistered(app_id, owner);
        emit AppTermsChanged(app_id, terms_hash, terms_uri);
        emit AppFeeChanged(app_id, fee);
    }

    function getAppOwner(bytes32 app_id) external view returns (address) {
        return apps[app_id].owner;
    }

    /// Publish (or update) an app's publisher agreement. Only callable by the app owner.
    ///
    /// Danger: every publisher who accepted the previous terms becomes unregistered
    /// until they accept the new ones.
    function setAppTerms(bytes32 app_id, bytes32 terms_hash, string calldata terms_uri) external onlyAppOwner(app_id) {
        if (terms_hash == bytes32(0)) revert TermsNotSet();
        App storage app = apps[app_id];
        app.appTerms = terms_hash;
        app.appTermsUri = terms_uri;
        // The owner accepts their own terms by publishing them. Without this they are
        // locked out of their own app by every edit.
        _joinOwner(app_id, msg.sender, terms_hash);
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

    /// Take an app down for every publisher at once (`true`), or put it back (`false`).
    /// Admin-only. Memberships are left intact, so putting it back restores them
    /// exactly.
    function setAppSuspended(bytes32 app_id, bool is_suspended) external onlyAdmin {
        App storage app = apps[app_id];
        if (app.owner == address(0)) revert AppNotFound();
        app.isAppSuspended = is_suspended;
        emit AppSuspensionChanged(app_id, is_suspended);
    }

    // ── Membership ────────────────────────────────────────────────────────────

    /// Add a publisher to this app. Only callable by the app owner.
    ///
    /// This is an invitation, not a membership: the publisher still has to accept the
    /// terms (and pay the join fee) with `registerForApp`. Nobody can join uninvited.
    /// Take an invitation back with `suspendForApp`.
    ///
    /// The publisher must not be banned network-wide: an owner cannot bring in a wallet
    /// the protocol admin has banned.
    function addPublisher(bytes32 app_id, address publisher) external onlyAppOwner(app_id) {
        if (globalSuspensions[publisher]) revert PublisherSuspendedGlobal();
        if (statusForApp[app_id][publisher] != Status.Unregistered) revert AlreadyRegistered();
        statusForApp[app_id][publisher] = Status.Invited;
        emit PublisherInvited(app_id, publisher);
    }

    /// Register to publish to an app. By registering, you are agreeing to the app's
    /// terms and conditions. The app owner must have added you first (`addPublisher`),
    /// and a wallet banned network-wide cannot accept.
    function registerForApp(bytes32 app_id, bytes32 terms_hash) external payable nonReentrant {
        App storage app = apps[app_id];
        Status status = _validateInvited(app, app_id, msg.sender);
        bytes32 current = app.appTerms;
        if (terms_hash != current) revert TermsMismatch();
        if (status == Status.Active && acceptedTerms[app_id][msg.sender] == current) revert AlreadyRegistered();

        // do not charge the join fee when accepting new publishing terms
        uint256 fee = status == Status.Active ? 0 : app.joinFee;
        if (msg.value != fee) revert JoinFeeMismatch();

        statusForApp[app_id][msg.sender] = Status.Active;
        acceptedTerms[app_id][msg.sender] = current;

        // paid directly to the app owner
        if (fee != 0) _sendEth(app.owner, fee);

        emit PublisherJoined(app_id, msg.sender, current, fee);
    }

    /// Suspend a publisher from only this app. Does not suspend globally.
    function suspendForApp(bytes32 app_id, address publisher) external onlyAppOwner(app_id) {
        if (statusForApp[app_id][publisher] == Status.Unregistered) revert NotInvited();
        statusForApp[app_id][publisher] = Status.Suspended;
        emit PublisherSuspendedForApp(app_id, publisher);
    }

    /// Unsuspend a publisher from the app. One who had joined is a member again; one
    /// whose invitation was taken back before they joined is invited again, and still
    /// has to accept the terms and pay the join fee.
    function reinstateForApp(bytes32 app_id, address publisher) external onlyAppOwner(app_id) {
        if (statusForApp[app_id][publisher] != Status.Suspended) revert PublisherNotSuspended();
        // Joining always records the terms accepted, and terms are never zero.
        statusForApp[app_id][publisher] =
            acceptedTerms[app_id][publisher] == bytes32(0) ? Status.Invited : Status.Active;
        emit PublisherReinstatedForApp(app_id, publisher);
    }

    // ── Publishing ────────────────────────────────────────────────────────────

    /// Commit a new state root for one of your subspaces in an app. This is the only
    /// way to publish: the DataRegistry accepts commits from this contract alone.
    ///
    /// The sender must be an active publisher of the app (`isRegisteredForApp`), or the
    /// commit reverts with the reason (see `_validatePublisher`). The DataRegistry then
    /// compare-and-swaps the head of `app_id:sender:subspace_id`,
    /// reverting `StaleStateRoot` if `old_root` is not the current head, and emits
    /// `StateCommitted`. A lapsed subscription does not stop a commit; the upload
    /// Worker enforces it.
    function commitStateRoot(bytes32 app_id, bytes32 subspace_id, bytes32 old_root, bytes32 new_root)
        external
        nonReentrant
    {
        _validatePublisher(app_id, msg.sender);
        IDataRegistry(dataRegistry).commitStateRoot(app_id, msg.sender, subspace_id, old_root, new_root);
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

    /// Is a publisher actively registered in an app? False if the publisher is banned
    /// network-wide or suspended from the app, merely invited, on stale terms, or the
    /// app is suspended. `commitStateRoot` requires it.
    ///
    /// The same rules as `_validatePublisher`, as a yes or no. Change both together:
    /// `test_each_refused_commit_says_why` checks that they agree.
    function isRegisteredForApp(bytes32 app_id, address publisher) public view returns (bool) {
        App storage app = apps[app_id];
        return !app.isAppSuspended && !globalSuspensions[publisher] && statusForApp[app_id][publisher] == Status.Active
            && acceptedTerms[app_id][publisher] == app.appTerms;
    }

    /// The single oracle the upload gate reads: `(registered, owner, expires_at)`.
    /// `registered` is `isRegisteredForApp`; `owner` is zero for an unclaimed app;
    /// `expires_at` is when the app's subscription expires, which the gate compares
    /// with the time.
    function access(bytes32 app_id, address publisher) external view returns (bool, address, uint64) {
        App storage app = apps[app_id];
        return (isRegisteredForApp(app_id, publisher), app.owner, app.expiry);
    }

    /// `(terms_hash, terms_uri, join_fee, status, registered)` — a join screen in one call
    function joinInfo(bytes32 app_id, address publisher)
        external
        view
        returns (bytes32, string memory, uint256, Status, bool)
    {
        App storage app = apps[app_id];
        return (
            app.appTerms,
            app.appTermsUri,
            app.joinFee,
            statusForApp[app_id][publisher],
            isRegisteredForApp(app_id, publisher)
        );
    }

    // ── Subscription (ERC-5643) ───────────────────────────────────────────────

    /// Pay for one more period. Callable by the app's owner, or an address they have
    /// approved for its token, who pays the subscription fee (USDC; `approve` this
    /// contract first).
    ///
    /// `duration` must be the subscription period, and the app must be renewable: a
    /// subscription with a period or more left cannot be paid further ahead. The
    /// period is added to the current expiry, or to now if it has passed.
    function renewSubscription(uint256 tokenId, uint64 duration) external payable nonReentrant {
        _checkAuthorized(_ownerOf(tokenId), msg.sender, tokenId);
        if (msg.value != 0) revert EthNotAccepted();
        if (duration != subscriptionPeriod) revert DurationMismatch();
        if (!isRenewable(tokenId)) revert SubscriptionNotRenewable();
        _paySubscription(bytes32(tokenId), msg.sender);
    }

    /// End the subscription now, as the standard does: the expiry becomes zero. Nothing
    /// is refunded. The app stays claimed, and renewing starts a new period from now.
    /// Callable by the app's owner, or an address they have approved for its token.
    function cancelSubscription(uint256 tokenId) external payable {
        _checkAuthorized(_ownerOf(tokenId), msg.sender, tokenId);
        if (msg.value != 0) revert EthNotAccepted();
        apps[bytes32(tokenId)].expiry = 0;
        emit SubscriptionUpdate(tokenId, 0);
    }

    function expiresAt(uint256 tokenId) external view returns (uint64) {
        _requireOwned(tokenId);
        return apps[bytes32(tokenId)].expiry;
    }

    /// True while less than one period is left, or the subscription has expired.
    function isRenewable(uint256 tokenId) public view returns (bool) {
        _requireOwned(tokenId);
        return apps[bytes32(tokenId)].expiry < block.timestamp + subscriptionPeriod;
    }

    function supportsInterface(bytes4 interface_id) public view override returns (bool) {
        return interface_id == type(IERC5643).interfaceId || super.supportsInterface(interface_id);
    }

    /// Mint only: an app's token is never transferred or burned, so its owner is
    /// always `App.owner`.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (_ownerOf(tokenId) != address(0)) revert NotTransferable();
        return super._update(to, tokenId, auth);
    }

    // ── Protocol admin ────────────────────────────────────────────────────────

    /// Hand the admin role to another address. The admin is also who may upgrade this
    /// contract, so setting zero renounces both for good.
    function setAdmin(address new_admin) external onlyAdmin {
        emit AdminChanged(admin, new_admin);
        admin = new_admin;
    }

    /// Only the admin may point the proxy at a new implementation.
    function _authorizeUpgrade(address) internal override onlyAdmin {}

    function setSubscriptionFee(uint256 fee) external onlyAdmin {
        subscriptionFee = fee;
        emit SubscriptionFeeChanged(fee);
    }

    /// Change how long one payment lasts. Expiries already set stay as they are; the
    /// new period applies from each app's next payment.
    function setSubscriptionPeriod(uint64 period) external onlyAdmin {
        _setSubscriptionPeriod(period);
    }

    /// Point commits at a DataRegistry. Until one is set, every commit reverts.
    function setDataRegistry(address registry) external onlyAdmin {
        dataRegistry = registry;
    }

    /// Ban a wallet network-wide (`true`), or lift the ban (`false`). A banned wallet
    /// can no longer claim an app, be added to one, join one, or publish in any
    /// (`isRegisteredForApp` turns false). Any address can be banned, including one that
    /// has never published. Nothing else is touched, so lifting the ban restores
    /// everything, and the wallet's timelines in the DataRegistry resume where they
    /// stopped.
    function setGlobalSuspension(address publisher, bool is_suspended) external onlyAdmin {
        globalSuspensions[publisher] = is_suspended;
        emit GlobalSuspensionChanged(publisher, is_suspended);
    }

    /// Sweep `amount` of collected USDC to `to`.
    function withdrawUsdc(address to, uint256 amount) external nonReentrant onlyAdmin {
        if (!_tokenCall(abi.encodeWithSignature("transfer(address,uint256)", to, amount))) revert TransferFailed();
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

    /// Mark an app owner as an active publisher of their own app
    function _joinOwner(bytes32 app_id, address owner, bytes32 terms_hash) private {
        statusForApp[app_id][owner] = Status.Active;
        acceptedTerms[app_id][owner] = terms_hash;
    }

    /// Pull the subscription fee from `payer` and add one period to the app's expiry,
    /// counted from now if it has passed.
    function _paySubscription(bytes32 app_id, address payer) private {
        uint256 fee = subscriptionFee;
        if (
            fee != 0
                && !_tokenCall(
                    abi.encodeWithSignature("transferFrom(address,address,uint256)", payer, address(this), fee)
                )
        ) revert SubscriptionFeeRequired();
        App storage app = apps[app_id];
        uint64 from = app.expiry > block.timestamp ? app.expiry : uint64(block.timestamp);
        uint64 expiry = from + subscriptionPeriod;
        app.expiry = expiry;
        emit SubscriptionUpdate(uint256(app_id), expiry);
    }

    function _setSubscriptionPeriod(uint64 period) private {
        if (period == 0) revert ZeroPeriod();
        subscriptionPeriod = period;
        emit SubscriptionPeriodChanged(period);
    }

    /// Call the fee token and require a clean `true` back. A revert, no contract at
    /// the address, or anything other than `true` is a failure.
    function _tokenCall(bytes memory data) private returns (bool) {
        (bool ok, bytes memory ret) = usdc.call(data);
        return ok && ret.length == 32 && abi.decode(ret, (uint256)) == 1;
    }

    /// Reverts unless `publisher` may publish under `app_id`, with the first reason that
    /// applies, from the most basic to the most specific. `isRegisteredForApp` is the
    /// same rules as a yes or no; change both together.
    function _validatePublisher(bytes32 app_id, address publisher) private view {
        App storage app = apps[app_id];
        if (_validateInvited(app, app_id, publisher) == Status.Invited) revert NotRegisteredForApp();
        if (acceptedTerms[app_id][publisher] != app.appTerms) revert TermsMismatch();
    }

    /// The checks joining and committing share, in the order both report them: the app
    /// exists, the publisher is not banned network-wide, the app is not taken down, and
    /// the publisher is in it and not suspended from it. Returns their status, which is
    /// then Invited or Active.
    function _validateInvited(App storage app, bytes32 app_id, address publisher) private view returns (Status status) {
        if (app.owner == address(0)) revert AppNotFound();
        if (globalSuspensions[publisher]) revert PublisherSuspendedGlobal();
        if (app.isAppSuspended) revert AppSuspended();
        status = statusForApp[app_id][publisher];
        if (status == Status.Suspended) revert PublisherSuspendedApp();
        if (status == Status.Unregistered) revert NotInvited();
    }

    function _sendEth(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
