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
/// it. A wallet claims an app (`registerApp`) and owns it; the owner invites publishers
/// (`invitePublisher`), who join by accepting the app's terms (`joinApp`). Only a publisher
/// who has joined may publish to the app's namespace in the DataRegistry
/// (`canPublish`).
///
/// An app IS a storage subscription: claiming one pulls the subscription fee (USDC)
/// for one period, and the off-chain upload gate reads `access` to decide whether to
/// serve its publishers.
///
/// Two payments, kept apart. The subscription fee is the protocol's: set by the admin,
/// paid in USDC by the app's owner, and held here until the admin withdraws it
/// (`withdrawToken`). The join fee is the app owner's: set by the owner, paid in ETH by
/// each publisher who joins, and credited to the owner (`withdrawJoinFees`).
///
/// Each app is also an ERC-721 token, minted to its owner at claim, and its
/// subscription follows ERC-5643: `expiresAt`, `isRenewable`, `renewSubscription` and
/// `cancelSubscription`. The token id and the app id are the same 32 bytes,
/// `uint256(app_id)`: the ERC-721 and ERC-5643 functions take the token id, the rest of
/// the contract the app id. The token cannot be transferred.
///
/// The expiry is recorded here but not enforced here: a lapsed or cancelled app can
/// still commit. The upload gate refuses its uploads.
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
        /// Never added to the app.
        None,
        /// Joined: accepted the app's terms and paid its join fee.
        Active,
        /// Joined, then suspended from the app by its owner.
        Suspended,
        /// Added by the app owner, terms not yet accepted.
        Invited
    }

    // Errors, grouped like the functions below.

    // Shared
    error Unauthorized();
    error TransferFailed();

    // Apps
    error AppNotFound();
    error AppAlreadyRegistered();
    /// Claiming or setting terms: the terms hash is zero. An app always has terms, so
    /// that there is something to accept.
    error TermsNotSet();
    /// The protocol admin has taken the app down (`setAppSuspended`)
    error AppSuspended();

    // Membership
    error NotInvited();
    /// `invitePublisher`: the wallet is already invited to, a member of, or suspended from
    /// this app
    error AlreadyInApp();
    /// Committing, accepting updated terms or being suspended: invited, but has not
    /// joined (`joinApp`). An invitation is taken back with `revokeInvitation`.
    error NotJoined();
    /// `joinApp`: the publisher has already joined. After the terms change, a member
    /// accepts the new ones with `acceptUpdatedTerms`, not by joining again.
    error AlreadyJoined();
    /// Joining or accepting updated terms: not the app's current terms. Committing: the
    /// terms the publisher accepted are no longer the app's; accept the new ones with
    /// `acceptUpdatedTerms`.
    error TermsMismatch();
    /// `acceptUpdatedTerms`: the publisher has already accepted the app's current terms
    error TermsAlreadyAccepted();
    /// `joinApp`: `msg.value` is not exactly the app's join fee
    error JoinFeeMismatch();
    /// `withdrawJoinFees`: the caller is owed nothing
    error NothingToWithdraw();
    /// The app's owner has suspended the publisher from this app (`setPublisherSuspended`)
    error PublisherSuspendedApp();
    /// `setPublisherSuspended(…, false)`: the publisher is not suspended from this app
    error PublisherNotSuspended();
    /// `setPublisherSuspended`: an app's owner cannot suspend themselves from it
    error CannotSuspendOwner();
    /// The protocol admin has suspended the publisher network-wide (`setGlobalSuspension`)
    error PublisherSuspendedGlobal();

    // Publishing
    /// Raised by the DataRegistry and passed through by `commitStateRoot`: `old_root` is
    /// not the current head. Declared here so it is in this contract's ABI.
    error StaleStateRoot();

    // Subscription
    error SubscriptionFeeRequired();
    /// `registerApp`: the subscription fee is above the most the caller agreed to pay
    error SubscriptionFeeTooHigh();
    /// The subscription has a period or more left; renew it once less than that remains
    error SubscriptionNotRenewable();
    /// `renewSubscription`: `duration` is not the subscription period
    error DurationMismatch();
    /// The subscription is paid in USDC; renewing or cancelling takes no ETH
    error EthNotAccepted();
    /// An app's token cannot be transferred or burned
    error NotTransferable();
    /// The subscription period cannot be zero
    error ZeroPeriod();

    // Events, grouped the same way. The subscription's own event, `SubscriptionUpdate`,
    // is ERC-5643's, declared in `IERC5643`.

    // Apps
    /// A wallet claimed an app
    event AppRegistered(bytes32 indexed app_id, address indexed owner);
    /// The app's terms changed and every publisher on the old hash must accept the new
    /// terms before they can publish again
    event AppTermsChanged(bytes32 indexed app_id, bytes32 terms_hash, string terms_uri);
    event JoinFeeChanged(bytes32 indexed app_id, uint256 join_fee);
    /// The app's agent card moved
    event AppAgentChanged(bytes32 indexed app_id, string agent_uri);
    /// The protocol admin suspended (or reinstated) an entire app
    event AppSuspensionChanged(bytes32 indexed app_id, bool suspended);

    // Membership
    /// An app owner added a publisher, who may now accept the terms and join
    event PublisherInvited(bytes32 indexed app_id, address indexed publisher);
    /// An app owner took back an invitation before it was accepted
    event InvitationRevoked(bytes32 indexed app_id, address indexed publisher);
    /// A publisher joined an app AND accepted `terms_hash`, paying `join_fee`
    event PublisherJoined(bytes32 indexed app_id, address indexed publisher, bytes32 terms_hash, uint256 join_fee);
    /// A member accepted the app's updated terms, `terms_hash`, and can publish again
    event UpdatedTermsAccepted(bytes32 indexed app_id, address indexed publisher, bytes32 terms_hash);
    /// An app owner took out the join fees they were owed
    event JoinFeesWithdrawn(address indexed owner, address to, uint256 amount);
    /// An app owner suspended a publisher from their app, or lifted the suspension
    event PublisherSuspensionChanged(bytes32 indexed app_id, address indexed publisher, bool suspended);
    /// The protocol admin banned a wallet network-wide, or lifted the ban
    event GlobalSuspensionChanged(address indexed publisher, bool suspended);

    // Protocol admin
    event SubscriptionFeeChanged(uint256 fee);
    /// The admin changed the period: it applies from each app's next payment
    event SubscriptionPeriodChanged(uint64 period);
    /// The admin pointed commits at another DataRegistry
    event DataRegistryChanged(address previous_registry, address new_registry);
    /// The admin sent an ERC-20 the contract held: subscription fees, or a token sent
    /// here by mistake
    event TokenWithdrawn(address indexed token, address indexed to, uint256 amount);
    event AdminChanged(address previous_admin, address new_admin);

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
        /// Zero means the app is unclaimed. Always the same as the token's owner
        /// (`ownerOf`): the token cannot move. Kept here as well so that every commit
        /// reads the owner, the takedown flag and the expiry from one storage slot.
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
    /// app owner => join fees paid to their apps and not yet withdrawn, in wei. The
    /// contract's ETH is these balances and nothing else (it has no `receive`).
    mapping(address => uint256) public joinFeesOwed;

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

    /// Register a unique app id.
    ///
    /// * `terms_hash`: the hash of the terms and conditions for using the app. Not zero.
    /// * `terms_uri`: where the terms can be read. NOT the app's agent card — that
    ///   goes in `setAppAgentUri`, which carries no hash precisely so that moving it
    ///   does not make every publisher accept the terms again.
    /// * `join_fee`: what joining the app costs a publisher, in wei
    /// * `max_subscription_fee`: the most the caller will pay for the first period. The
    ///   fee charged is `subscriptionFee()` when the registration lands; if the admin has raised
    ///   it above this in the meantime, the registration reverts instead.
    ///
    /// The caller becomes the app's first publisher, already joined.
    ///
    /// Registration pays the subscription fee (USDC) for one period, so an app cannot exist
    /// unpaid. The caller must `approve` this contract for `subscriptionFee()` first.
    /// It mints the app's token to the caller.
    ///
    /// The caller must not be banned network-wide (`globalSuspensions`), so a wallet the
    /// protocol admin has banned cannot come back as an app owner.
    function registerApp(
        bytes32 app_id,
        bytes32 terms_hash,
        string calldata terms_uri,
        uint256 join_fee,
        uint256 max_subscription_fee
    ) external nonReentrant {
        App storage app = apps[app_id];
        address owner = msg.sender;
        if (globalSuspensions[owner]) revert PublisherSuspendedGlobal();
        if (app.owner != address(0)) revert AppAlreadyRegistered();
        if (terms_hash == bytes32(0)) revert TermsNotSet();
        if (subscriptionFee > max_subscription_fee) revert SubscriptionFeeTooHigh();
        _paySubscription(app_id, owner);

        app.owner = owner;
        app.appTerms = terms_hash;
        app.appTermsUri = terms_uri;
        app.joinFee = join_fee;
        _joinOwner(app_id, owner, terms_hash);
        _mint(owner, uint256(app_id));

        emit AppRegistered(app_id, owner);
        emit AppTermsChanged(app_id, terms_hash, terms_uri);
        emit JoinFeeChanged(app_id, join_fee);
    }

    function getAppOwner(bytes32 app_id) external view returns (address) {
        return apps[app_id].owner;
    }

    /// Publish (or update) an app's publisher agreement. Only callable by the app owner.
    ///
    /// Note: every publisher who accepted the previous terms can no longer publish
    /// until they accept the new ones (`acceptUpdatedTerms`, free).
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
    function setJoinFee(bytes32 app_id, uint256 join_fee) external onlyAppOwner(app_id) {
        apps[app_id].joinFee = join_fee;
        emit JoinFeeChanged(app_id, join_fee);
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

    /// Invite a publisher to this app. Only callable by the app owner.
    ///
    /// This is an invitation, not a membership: the publisher still has to accept the
    /// terms (and pay the join fee) with `joinApp`. Nobody can join uninvited.
    /// Take an invitation back with `revokeInvitation`.
    ///
    /// The publisher must not be banned network-wide: an owner cannot bring in a wallet
    /// the protocol admin has banned.
    function invitePublisher(bytes32 app_id, address publisher) external onlyAppOwner(app_id) {
        if (globalSuspensions[publisher]) revert PublisherSuspendedGlobal();
        if (statusForApp[app_id][publisher] != Status.None) revert AlreadyInApp();
        statusForApp[app_id][publisher] = Status.Invited;
        emit PublisherInvited(app_id, publisher);
    }

    /// Join an app as a publisher, once. By joining, you agree to the app's current terms
    /// (`terms_hash`) and pay exactly its join fee. The app owner must have added you
    /// first (`invitePublisher`), and a wallet banned network-wide cannot join.
    ///
    /// The join fee is credited to the app owner, who takes it out with
    /// `withdrawJoinFees`. Nothing is sent during the join, so the owner's code never
    /// runs in the joiner's transaction.
    function joinApp(bytes32 app_id, bytes32 terms_hash) external payable {
        App storage app = apps[app_id];
        if (_validateForApp(app, app_id, msg.sender) == Status.Active) revert AlreadyJoined();
        bytes32 current = app.appTerms;
        if (terms_hash != current) revert TermsMismatch();
        uint256 join_fee = app.joinFee;
        if (msg.value != join_fee) revert JoinFeeMismatch();

        statusForApp[app_id][msg.sender] = Status.Active;
        acceptedTerms[app_id][msg.sender] = current;
        if (join_fee != 0) joinFeesOwed[app.owner] += join_fee;

        emit PublisherJoined(app_id, msg.sender, current, join_fee);
    }

    /// Accept the app's updated terms (`terms_hash`), as a member whose accepted terms
    /// the owner has since replaced. Free: an owner must not be able to bill every
    /// member by editing the terms. Until a member accepts, they cannot publish.
    function acceptUpdatedTerms(bytes32 app_id, bytes32 terms_hash) external {
        App storage app = apps[app_id];
        if (_validateForApp(app, app_id, msg.sender) == Status.Invited) revert NotJoined();
        bytes32 current = app.appTerms;
        if (terms_hash != current) revert TermsMismatch();
        if (acceptedTerms[app_id][msg.sender] == current) revert TermsAlreadyAccepted();

        acceptedTerms[app_id][msg.sender] = current;
        emit UpdatedTermsAccepted(app_id, msg.sender, current);
    }

    /// Take out every join fee owed to you, the owner of one or more apps, and send it
    /// to `to`. An owner that cannot receive ETH itself names an address that can.
    function withdrawJoinFees(address to) external nonReentrant {
        uint256 amount = joinFeesOwed[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        joinFeesOwed[msg.sender] = 0;
        _sendEth(to, amount);
        emit JoinFeesWithdrawn(msg.sender, to, amount);
    }

    /// Take back an invitation the publisher has not accepted yet. They are as if never
    /// invited: they cannot join, and the owner can invite them again (`invitePublisher`).
    /// Only callable by the app owner. Reverts `NotInvited` for a wallet the app does not
    /// know, and `AlreadyJoined` for one who has joined; a member is suspended instead.
    function revokeInvitation(bytes32 app_id, address publisher) external onlyAppOwner(app_id) {
        Status status = statusForApp[app_id][publisher];
        if (status == Status.None) revert NotInvited();
        if (status != Status.Invited) revert AlreadyJoined();
        statusForApp[app_id][publisher] = Status.None;
        emit InvitationRevoked(app_id, publisher);
    }

    /// Suspend a member from this app (`true`), or lift the suspension (`false`). Only
    /// callable by the app owner, and only for this app: a network-wide ban is the
    /// protocol admin's (`setGlobalSuspension`).
    ///
    /// Only a publisher who has joined can be suspended (`NotJoined` for one only
    /// invited: take the invitation back with `revokeInvitation`), so lifting a
    /// suspension always makes them a member again. Unlike the other suspension setters,
    /// lifting one that is not there reverts (`PublisherNotSuspended`), since it would
    /// otherwise change the publisher's status. The owner cannot suspend themselves
    /// (`CannotSuspendOwner`): an owner's membership of their own app is not theirs to
    /// take away.
    function setPublisherSuspended(bytes32 app_id, address publisher, bool is_suspended) external onlyAppOwner(app_id) {
        Status status = statusForApp[app_id][publisher];
        if (is_suspended) {
            if (publisher == msg.sender) revert CannotSuspendOwner();
            if (status == Status.None) revert NotInvited();
            if (status == Status.Invited) revert NotJoined();
            statusForApp[app_id][publisher] = Status.Suspended;
        } else {
            if (status != Status.Suspended) revert PublisherNotSuspended();
            statusForApp[app_id][publisher] = Status.Active;
        }
        emit PublisherSuspensionChanged(app_id, publisher, is_suspended);
    }

    // ── Publishing ────────────────────────────────────────────────────────────

    /// Commit a new state root for one of your subspaces in an app. This is the only
    /// way to publish: the DataRegistry accepts commits from this contract alone.
    ///
    /// The sender must be an active publisher of the app (`canPublish`), or the
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

    function joinFee(bytes32 app_id) external view returns (uint256) {
        return apps[app_id].joinFee;
    }

    function appAgentUri(bytes32 app_id) external view returns (string memory) {
        return apps[app_id].appAgentUri;
    }

    function isAppSuspended(bytes32 app_id) external view returns (bool) {
        return apps[app_id].isAppSuspended;
    }

    /// May `publisher` publish to the app now? False if the publisher is banned
    /// network-wide or suspended from the app, merely invited, on stale terms, or the
    /// app is suspended. `commitStateRoot` requires it.
    ///
    /// The same rules as `_validatePublisher`, but as a yes or no. Change both together:
    /// `test_each_refused_commit_says_why` checks that they agree.
    function canPublish(bytes32 app_id, address publisher) public view returns (bool) {
        App storage app = apps[app_id];
        return !app.isAppSuspended && !globalSuspensions[publisher] && statusForApp[app_id][publisher] == Status.Active
            && acceptedTerms[app_id][publisher] == app.appTerms;
    }

    /// The single oracle the upload gate reads: `(can_publish, owner, expires_at)`.
    /// `can_publish` is `canPublish`; `owner` is zero for an unclaimed app;
    /// `expires_at` is when the app's subscription expires, which the gate compares
    /// with the time.
    function access(bytes32 app_id, address publisher) external view returns (bool, address, uint64) {
        App storage app = apps[app_id];
        return (canPublish(app_id, publisher), app.owner, app.expiry);
    }

    /// `(terms_hash, terms_uri, join_fee, status, can_publish)` — a join screen in one call
    function joinInfo(bytes32 app_id, address publisher)
        external
        view
        returns (bytes32, string memory, uint256, Status, bool)
    {
        App storage app = apps[app_id];
        return
            (app.appTerms, app.appTermsUri, app.joinFee, statusForApp[app_id][publisher], canPublish(app_id, publisher));
    }

    // ── Subscription (ERC-5643) ───────────────────────────────────────────────

    /// Pay for one more period. Callable by the app's owner, or an address they have
    /// approved for its token, who pays the subscription fee (USDC; `approve` this
    /// contract first).
    ///
    /// The fee charged is `subscriptionFee()` when the renewal lands. The standard
    /// fixes this function's arguments, so there is no maximum-fee argument here: the
    /// payer's allowance is the cap. Approve exactly the fee, and a fee raised in the
    /// meantime makes the renewal revert instead of charging more.
    ///
    /// `duration` must be the subscription period, and the app must be renewable: a
    /// subscription with a period or more left cannot be paid further ahead. The
    /// period is added to the current expiry, or to now if it has passed.
    ///
    /// `payable` only because ERC-5643 declares it so: the fee is USDC, and ETH sent
    /// with it reverts.
    function renewSubscription(uint256 tokenId, uint64 duration) external payable nonReentrant {
        _checkAuthorized(_ownerOf(tokenId), msg.sender, tokenId);
        if (msg.value != 0) revert EthNotAccepted();
        if (duration != subscriptionPeriod) revert DurationMismatch();
        if (!isRenewable(tokenId)) revert SubscriptionNotRenewable();
        _paySubscription(bytes32(tokenId), msg.sender);
    }

    /// End the subscription now, as the standard does: the expiry becomes zero. Nothing
    /// is refunded. The app stays claimed, and renewing starts a new period from now.
    /// Only the app's owner may cancel: an address they approved for the token can
    /// renew it, but not end it. `payable` only because ERC-5643 declares it so; ETH
    /// sent with it reverts.
    function cancelSubscription(uint256 tokenId) external payable {
        if (_requireOwned(tokenId) != msg.sender) revert Unauthorized();
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

    /// Change the subscription fee, in USDC base units. It applies from the next claim
    /// or renewal, within what the payer has capped (see `registerApp`, `renewSubscription`).
    function setSubscriptionFee(uint256 fee) external onlyAdmin {
        subscriptionFee = fee;
        emit SubscriptionFeeChanged(fee);
    }

    /// Change how long one payment lasts. Expiries already set stay as they are; the
    /// new period applies from each app's next payment.
    ///
    /// It does move when apps may next renew: `isRenewable` compares an app's expiry
    /// with now plus the current period, so a longer period lets every app renew
    /// sooner, and a shorter one later.
    function setSubscriptionPeriod(uint64 period) external onlyAdmin {
        _setSubscriptionPeriod(period);
    }

    /// Point commits at a DataRegistry. Until one is set, every commit reverts.
    function setDataRegistry(address registry) external onlyAdmin {
        emit DataRegistryChanged(dataRegistry, registry);
        dataRegistry = registry;
    }

    /// Ban a wallet network-wide (`true`), or lift the ban (`false`). A banned wallet
    /// can no longer claim an app, be added to one, join one, or publish in any
    /// (`canPublish` turns false). Any address can be banned, including one that
    /// has never published. Nothing else is touched, so lifting the ban restores
    /// everything, and the wallet's timelines in the DataRegistry resume where they
    /// stopped.
    function setGlobalSuspension(address publisher, bool is_suspended) external onlyAdmin {
        globalSuspensions[publisher] = is_suspended;
        emit GlobalSuspensionChanged(publisher, is_suspended);
    }

    /// Send `amount` of an ERC-20 the contract holds to `to`: the collected subscription
    /// fees (USDC), or any token sent here by mistake.
    function withdrawToken(address token, address to, uint256 amount) external nonReentrant onlyAdmin {
        if (!_tokenCall(token, abi.encodeWithSignature("transfer(address,uint256)", to, amount))) {
            revert TransferFailed();
        }
        emit TokenWithdrawn(token, to, amount);
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
                    usdc, abi.encodeWithSignature("transferFrom(address,address,uint256)", payer, address(this), fee)
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

    /// Call an ERC-20 and require a clean `true` back. A revert, no contract at the
    /// address, or anything other than `true` is a failure.
    function _tokenCall(address token, bytes memory data) private returns (bool) {
        (bool ok, bytes memory ret) = token.call(data);
        return ok && ret.length == 32 && abi.decode(ret, (uint256)) == 1;
    }

    /// Reverts unless `publisher` may publish under `app_id`, with the first reason that
    /// applies, from the most basic to the most specific. `canPublish` is the
    /// same rules as a yes or no; change both together.
    function _validatePublisher(bytes32 app_id, address publisher) private view {
        App storage app = apps[app_id];
        if (_validateForApp(app, app_id, publisher) == Status.Invited) revert NotJoined();
        if (acceptedTerms[app_id][publisher] != app.appTerms) revert TermsMismatch();
    }

    /// The checks joining, accepting updated terms and committing share, in the order
    /// all three report them: the app exists, the publisher is not banned network-wide,
    /// the app is not taken down, and the publisher is in it and not suspended from it.
    /// Returns their status, which is then Invited or Active.
    function _validateForApp(App storage app, bytes32 app_id, address publisher) private view returns (Status status) {
        if (app.owner == address(0)) revert AppNotFound();
        if (globalSuspensions[publisher]) revert PublisherSuspendedGlobal();
        if (app.isAppSuspended) revert AppSuspended();
        status = statusForApp[app_id][publisher];
        if (status == Status.Suspended) revert PublisherSuspendedApp();
        if (status == Status.None) revert NotInvited();
    }

    function _sendEth(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
