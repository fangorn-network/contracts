// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {NonReentrant} from "./NonReentrant.sol";

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

/// ERC-3009
interface IERC3009 {
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

interface IAppRegistry {
    function getAppOwner(bytes32 app_id) external view returns (address);
}

/// ERC-4907: tokens with expirable 'user'
interface IERC4907 {
    event UpdateUser(uint256 indexed tokenId, address indexed user, uint64 expires);

    function setUser(uint256 tokenId, address user, uint64 expires) external;
    function userOf(uint256 tokenId) external view returns (address);
    function userExpires(uint256 tokenId) external view returns (uint256);
}

/// ERC-5192: non-transferrable token
interface IERC5192 {
    event Locked(uint256 tokenId);
    event Unlocked(uint256 tokenId);

    function locked(uint256 tokenId) external view returns (bool);
}

/// ERC-5643: an expirable token
interface IERC5643 {
    event SubscriptionUpdate(uint256 indexed tokenId, uint64 expiration);

    function renewSubscription(uint256 tokenId, uint64 duration) external payable;
    function cancelSubscription(uint256 tokenId) external payable;
    function expiresAt(uint256 tokenId) external view returns (uint64);
    function isRenewable(uint256 tokenId) external view returns (bool);
}

/// MembershipRegistry
///
/// Time-limited access to an app's paid records, held by an address nobody can tie to
/// the wallet that paid. Replaces the SettlementRegistry: the "resource" is now one app
/// for one period, and settling mints or extends a membership token.
///
///   join   the payer signs an ERC-3009 `receiveWithAuthorization` for the app's price,
///          and their Semaphore identity commitment joins the group of (app, epoch). The
///          signature's nonce is keccak256(app_id, epoch, commitment, salt), so whoever
///          submits it cannot swap in another commitment, and only this contract can
///          redeem it.
///   claim  later, from anywhere, a Semaphore proof of membership in that group, with the
///          holder as its message, mints the holder's membership or extends it by one
///          period. One claim per payment (one nullifier per scope).
///
/// The token is ERC-721, locked (ERC-5192), expiring (ERC-5643's reads), with one user
/// (ERC-4907): the agent its holder names, never past the membership's own expiry.
/// `setUserBySig` lets a holder with no gas name it; anyone may submit the signature.
///
/// Deployed behind an ERC-1967 proxy (UUPS). Storage is append-only.
contract MembershipRegistry is Initializable, UUPSUpgradeable, ERC721, EIP712, NonReentrant, IERC4907, IERC5192, IERC5643 {
    using SafeERC20 for IERC20;

    error Unauthorized();
    error NoPlan();
    error WrongAmount();
    error NonceNotBound();
    error NoGroup();
    error AlreadyClaimed();
    error NotTransferable();
    error Expired();
    error UseJoinAndClaim();

    event PlanSet(bytes32 indexed app_id, uint256 price, uint64 period);
    event Joined(bytes32 indexed app_id, uint256 indexed epoch, uint256 commitment);
    event Claimed(bytes32 indexed app_id, uint256 indexed epoch, uint256 indexed tokenId, address holder);
    event AdminChanged(address previousAdmin, address newAdmin);

    struct Plan {
        uint256 price;
        uint64 period;
    }

    struct User {
        address user;
        uint64 expires;
    }

    /// A signed ERC-3009 `receiveWithAuthorization` to this contract.
    struct Payment {
        address from;
        uint256 value;
        uint256 validAfter;
        uint256 validBefore;
        bytes32 nonce;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    bytes32 private constant SET_USER_TYPEHASH =
        keccak256("SetUser(uint256 tokenId,address user,uint64 expires,uint256 nonce,uint256 deadline)");

    address public admin;
    address public usdc;
    address public semaphore;
    address public appRegistry;

    mapping(bytes32 => Plan) internal plans;
    /// keccak256(app_id, epoch) => Semaphore group id + 1 (zero: not created yet)
    mapping(bytes32 => uint256) internal groups;
    /// nullifiers already claimed
    mapping(uint256 => bool) internal claimed;
    mapping(uint256 => bytes32) internal appOf;
    mapping(uint256 => uint64) internal expiry;
    mapping(uint256 => User) internal users;
    /// per token, for setUserBySig replay protection
    mapping(uint256 => uint256) public userNonces;

    /// ERC721's and EIP712's constructors only write the implementation's own storage and
    /// immutables: `name`/`symbol` are overridden below, and EIP712's values are immutables,
    /// which the proxy reads from this code.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() ERC721("", "") EIP712("Fangorn Membership", "1") {
        _disableInitializers();
    }

    function initialize(address admin_, address usdc_, address semaphore_, address appRegistry_) external initializer {
        admin = admin_;
        usdc = usdc_;
        semaphore = semaphore_;
        appRegistry = appRegistry_;
    }

    function name() public pure override returns (string memory) {
        return "Fangorn Membership";
    }

    function symbol() public pure override returns (string memory) {
        return "FMEMBER";
    }

    // ── Plans ─────────────────────────────────────────────────────────────────

    /// Set what a period of membership in `app_id` costs (USDC base units) and how long a
    /// period is. Price zero: the app offers none. Only the app's owner (AppRegistry).
    /// Changing `period` renumbers epochs; do it rarely.
    function setPlan(bytes32 app_id, uint256 price, uint64 period) external {
        if (msg.sender != IAppRegistry(appRegistry).getAppOwner(app_id)) revert Unauthorized();
        if (price != 0 && period == 0) revert NoPlan();
        plans[app_id] = Plan(price, period);
        emit PlanSet(app_id, price, period);
    }

    function planOf(bytes32 app_id) external view returns (uint256 price, uint64 period) {
        Plan memory p = plans[app_id];
        return (p.price, p.period);
    }

    function currentEpoch(bytes32 app_id) public view returns (uint256) {
        uint64 period = plans[app_id].period;
        if (period == 0) revert NoPlan();
        return block.timestamp / period;
    }

    /// The nonce a payer signs for `join`: binds the payment to this app, epoch and
    /// commitment.
    function joinNonce(bytes32 app_id, uint256 epoch, uint256 commitment, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode(app_id, epoch, commitment, salt));
    }

    function scopeOf(bytes32 app_id, uint256 epoch) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(app_id, epoch)));
    }

    /// The Semaphore group of (app, epoch); reverts if nobody has joined it yet.
    function groupOf(bytes32 app_id, uint256 epoch) public view returns (uint256) {
        uint256 g = groups[keccak256(abi.encode(app_id, epoch))];
        if (g == 0) revert NoGroup();
        return g - 1;
    }

    function tokenIdOf(bytes32 app_id, address holder) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(app_id, holder)));
    }

    // ── Join and claim ────────────────────────────────────────────────────────

    function join(bytes32 app_id, uint256 commitment, bytes32 salt, Payment calldata pay) external nonReentrant {
        Plan memory p = plans[app_id];
        if (p.price == 0) revert NoPlan();
        if (pay.value != p.price) revert WrongAmount();
        uint256 epoch = block.timestamp / p.period;
        if (pay.nonce != joinNonce(app_id, epoch, commitment, salt)) revert NonceNotBound();

        IERC3009(usdc).receiveWithAuthorization(
            pay.from, address(this), pay.value, pay.validAfter, pay.validBefore, pay.nonce, pay.v, pay.r, pay.s
        );
        IERC20(usdc).safeTransfer(IAppRegistry(appRegistry).getAppOwner(app_id), pay.value);

        bytes32 key = keccak256(abi.encode(app_id, epoch));
        uint256 g = groups[key];
        if (g == 0) {
            g = ISemaphore(semaphore).createGroup() + 1;
            groups[key] = g;
        }
        ISemaphore(semaphore).addMember(g - 1, commitment);
        emit Joined(app_id, epoch, commitment);
    }

    function claim(
        bytes32 app_id,
        uint256 epoch,
        address holder,
        uint256 merkleTreeDepth,
        uint256 merkleTreeRoot,
        uint256 nullifier,
        uint256[8] calldata points
    ) external nonReentrant returns (uint256 tokenId) {
        Plan memory p = plans[app_id];
        if (p.period == 0) revert NoPlan();
        if (claimed[nullifier]) revert AlreadyClaimed();
        // The scope is fixed here, not taken from the caller: a proof under any other scope
        // would carry another nullifier and claim the same payment twice. The message is
        // the holder, so whoever submits the proof cannot redirect the membership.
        ISemaphore(semaphore).validateProof(
            groupOf(app_id, epoch),
            ISemaphore.SemaphoreProof({
                merkleTreeDepth: merkleTreeDepth,
                merkleTreeRoot: merkleTreeRoot,
                nullifier: nullifier,
                message: uint256(uint160(holder)),
                scope: scopeOf(app_id, epoch),
                points: points
            })
        );
        claimed[nullifier] = true;

        tokenId = tokenIdOf(app_id, holder);
        if (_ownerOf(tokenId) == address(0)) {
            _mint(holder, tokenId);
            appOf[tokenId] = app_id;
            emit Locked(tokenId);
        }
        uint64 from = expiry[tokenId] > block.timestamp ? expiry[tokenId] : uint64(block.timestamp);
        uint64 until = from + p.period;
        expiry[tokenId] = until;
        emit SubscriptionUpdate(tokenId, until);
        emit Claimed(app_id, epoch, tokenId, holder);
    }

    // ── Reads ─────────────────────────────────────────────────────────────────

    /// What a reader may read with `tokenId`, and until when: the membership's expiry for
    /// its holder, the user's expiry for its user, else zero.
    function canRead(uint256 tokenId, address who) external view returns (bytes32 app_id, uint64 until) {
        app_id = appOf[tokenId];
        address holder = _ownerOf(tokenId);
        if (holder == address(0) || who == address(0)) return (app_id, 0);
        if (who == holder) return (app_id, expiry[tokenId]);
        if (who == users[tokenId].user) return (app_id, uint64(userExpires(tokenId)));
        return (app_id, 0);
    }

    function appOfToken(uint256 tokenId) external view returns (bytes32) {
        return appOf[tokenId];
    }

    // ── ERC-5643 ──────────────────────────────────────────────────────────────

    function expiresAt(uint256 tokenId) external view returns (uint64) {
        _requireOwned(tokenId);
        return expiry[tokenId];
    }

    function isRenewable(uint256 tokenId) external view returns (bool) {
        return plans[appOf[tokenId]].price != 0;
    }

    /// Renewal is join + claim, so that the payer stays unlinked from the holder.
    function renewSubscription(uint256, uint64) external payable {
        revert UseJoinAndClaim();
    }

    /// A membership ends by not renewing.
    function cancelSubscription(uint256) external payable {
        revert UseJoinAndClaim();
    }

    // ── ERC-5192 ──────────────────────────────────────────────────────────────

    function locked(uint256 tokenId) external view returns (bool) {
        _requireOwned(tokenId);
        return true;
    }

    /// Mint only: every transfer and burn reverts.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (_ownerOf(tokenId) != address(0)) revert NotTransferable();
        return super._update(to, tokenId, auth);
    }

    // ── ERC-4907 ──────────────────────────────────────────────────────────────

    function setUser(uint256 tokenId, address user, uint64 expires) external {
        if (msg.sender != ownerOf(tokenId)) revert Unauthorized();
        _setUser(tokenId, user, expires);
    }

    /// `setUser`, signed (EIP-712, or ERC-1271 for a contract wallet) by the holder.
    function setUserBySig(uint256 tokenId, address user, uint64 expires, uint256 deadline, bytes calldata signature)
        external
    {
        if (block.timestamp > deadline) revert Expired();
        address holder = ownerOf(tokenId);
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(SET_USER_TYPEHASH, tokenId, user, expires, userNonces[tokenId]++, deadline))
        );
        if (!SignatureChecker.isValidSignatureNow(holder, digest, signature)) revert Unauthorized();
        _setUser(tokenId, user, expires);
    }

    function userOf(uint256 tokenId) public view returns (address) {
        User memory u = users[tokenId];
        return u.expires >= block.timestamp && expiry[tokenId] >= block.timestamp ? u.user : address(0);
    }

    /// The earlier of the user's date and the membership's.
    function userExpires(uint256 tokenId) public view returns (uint256) {
        uint64 u = users[tokenId].expires;
        uint64 m = expiry[tokenId];
        return u < m ? u : m;
    }

    function _setUser(uint256 tokenId, address user, uint64 expires) private {
        users[tokenId] = User(user, expires);
        emit UpdateUser(tokenId, user, expires);
    }

    function supportsInterface(bytes4 id) public view override returns (bool) {
        return id == type(IERC4907).interfaceId || id == type(IERC5192).interfaceId
            || id == type(IERC5643).interfaceId || super.supportsInterface(id);
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    function setAdmin(address new_admin) external {
        if (msg.sender != admin) revert Unauthorized();
        emit AdminChanged(admin, new_admin);
        admin = new_admin;
    }

    function _authorizeUpgrade(address) internal view override {
        if (msg.sender != admin) revert Unauthorized();
    }
}
