// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

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

/// SettlementRegistry
///
/// Sells read access to a repo, or to one record of it, on terms its publisher signs.
/// A subject is (publisher, repo, key), where `repo` is keccak256 of the repo's name and
/// key zero is the whole repo.
///
///   register  pays the terms' price and adds a Semaphore commitment to the subject's
///             group. A referrer the publisher has not denied gets `shareBps` of it.
///   settle    a proof of membership in that group, with the reader as its message,
///             marks the reader as settled for the subject. One settle per payment.
///
/// Raising a repo's generation voids every terms signed for it before.
///
/// Deployed behind an ERC-1967 proxy (UUPS). Storage is append-only.
contract SettlementRegistry is Initializable, UUPSUpgradeable, EIP712Upgradeable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    error Unauthorized();
    error Expired();
    error StaleTerms();
    error BadShare();
    error BadSignature();
    error WrongAmount();
    error NonceNotBound();
    error AlreadyRegistered();
    error AlreadySettled();
    error Disabled();
    error NoGroup();

    event Registered(
        bytes32 indexed subject,
        address indexed publisher,
        address indexed referrer,
        uint256 commitment,
        uint256 price,
        uint256 referrer_cut
    );
    event Settled(bytes32 indexed subject, uint256 indexed nullifier, address reader);
    event GenerationRaised(address indexed publisher, bytes32 indexed repo, uint64 generation);
    event DenialSet(address indexed publisher, address indexed referrer, bool denied);
    event DisabledSet(bytes32 indexed subject, bool disabled, address by);
    event AdminChanged(address previous_admin, address new_admin);

    struct Terms {
        address publisher;
        bytes32 repo;
        bytes32 key;
        uint256 price;
        uint16 shareBps;
        uint64 generation;
        uint64 deadline;
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

    bytes32 public constant TERMS_TYPEHASH = keccak256(
        "Terms(address publisher,bytes32 repo,bytes32 key,uint256 price,uint16 shareBps,uint64 generation,uint64 deadline)"
    );
    uint16 internal constant BPS = 10_000;

    address public admin;
    address public usdc;
    address public semaphore;

    /// publisher => repo => generation
    mapping(address => mapping(bytes32 => uint64)) public generationOf;
    /// publisher => referrer => denied
    mapping(address => mapping(address => bool)) public isDenied;
    mapping(bytes32 => bool) public isDisabled;
    /// subject => Semaphore group id + 1 (zero: not created yet)
    mapping(bytes32 => uint256) internal groups;
    /// keccak256(subject, commitment)
    mapping(bytes32 => bool) internal registered;
    mapping(uint256 => bool) internal nullifiers;
    /// keccak256(reader, subject)
    mapping(bytes32 => bool) internal settled;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin_, address usdc_, address semaphore_) external initializer {
        __EIP712_init("Fangorn Settlement", "1");
        admin = admin_;
        usdc = usdc_;
        semaphore = semaphore_;
    }

    // ── Ids ───────────────────────────────────────────────────────────────────

    function subjectOf(address publisher, bytes32 repo, bytes32 key) public pure returns (bytes32) {
        return keccak256(abi.encode(publisher, repo, key));
    }

    /// The nonce a payer signs: binds the payment to its subject, commitment and referrer.
    function registerNonce(bytes32 subject, uint256 commitment, address referrer, bytes32 salt)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(subject, commitment, referrer, salt));
    }

    function hashTerms(Terms calldata t) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(TERMS_TYPEHASH, t.publisher, t.repo, t.key, t.price, t.shareBps, t.generation, t.deadline)
            )
        );
    }

    // ── Publisher ─────────────────────────────────────────────────────────────

    function raiseGeneration(bytes32 repo) external returns (uint64 generation) {
        generation = ++generationOf[msg.sender][repo];
        emit GenerationRaised(msg.sender, repo, generation);
    }

    function setDenied(address referrer, bool denied) external {
        isDenied[msg.sender][referrer] = denied;
        emit DenialSet(msg.sender, referrer, denied);
    }

    /// Stops registrations, settles and `canRead` for a subject. Disabling a repo also
    /// stops registrations and `canRead` for each of its records. Its publisher or the admin.
    function setDisabled(address publisher, bytes32 repo, bytes32 key, bool disabled) external {
        if (msg.sender != publisher && msg.sender != admin) revert Unauthorized();
        bytes32 subject = subjectOf(publisher, repo, key);
        isDisabled[subject] = disabled;
        emit DisabledSet(subject, disabled, msg.sender);
    }

    // ── Register and settle ───────────────────────────────────────────────────

    /// `pay` is ignored when the price is zero.
    function register(
        Terms calldata t,
        bytes calldata signature,
        uint256 commitment,
        address referrer,
        bytes32 salt,
        Payment calldata pay
    ) external nonReentrant returns (bytes32 subject) {
        if (block.timestamp > t.deadline) revert Expired();
        if (t.generation != generationOf[t.publisher][t.repo]) revert StaleTerms();
        if (t.shareBps > BPS) revert BadShare();
        if (!SignatureChecker.isValidSignatureNow(t.publisher, hashTerms(t), signature)) revert BadSignature();

        subject = subjectOf(t.publisher, t.repo, t.key);
        if (isDisabled[subject] || isDisabled[subjectOf(t.publisher, t.repo, bytes32(0))]) revert Disabled();
        bytes32 reg = keccak256(abi.encode(subject, commitment));
        if (registered[reg]) revert AlreadyRegistered();
        registered[reg] = true;

        uint256 cut;
        if (t.price != 0) {
            if (pay.value != t.price) revert WrongAmount();
            if (pay.nonce != registerNonce(subject, commitment, referrer, salt)) revert NonceNotBound();
            IERC3009(usdc)
                .receiveWithAuthorization(
                    pay.from, address(this), pay.value, pay.validAfter, pay.validBefore, pay.nonce, pay.v, pay.r, pay.s
                );
            if (referrer != address(0) && referrer != t.publisher && !isDenied[t.publisher][referrer]) {
                cut = t.price * t.shareBps / BPS;
            }
            if (cut != 0) IERC20(usdc).safeTransfer(referrer, cut);
            IERC20(usdc).safeTransfer(t.publisher, t.price - cut);
        }

        uint256 g = groups[subject];
        if (g == 0) {
            g = ISemaphore(semaphore).createGroup() + 1;
            groups[subject] = g;
        }
        ISemaphore(semaphore).addMember(g - 1, commitment);
        emit Registered(subject, t.publisher, referrer, commitment, t.price, cut);
    }

    function settle(
        bytes32 subject,
        address reader,
        uint256 merkleTreeDepth,
        uint256 merkleTreeRoot,
        uint256 nullifier,
        uint256[8] calldata points
    ) external nonReentrant {
        if (isDisabled[subject]) revert Disabled();
        if (nullifiers[nullifier]) revert AlreadySettled();
        // Scope and message are fixed here: a proof under another scope would carry another
        // nullifier, and one with another message would hand the access to someone else.
        ISemaphore(semaphore)
            .validateProof(
                groupOf(subject),
                ISemaphore.SemaphoreProof({
                merkleTreeDepth: merkleTreeDepth,
                merkleTreeRoot: merkleTreeRoot,
                nullifier: nullifier,
                message: uint256(uint160(reader)),
                scope: uint256(subject),
                points: points
            })
            );
        nullifiers[nullifier] = true;
        settled[keccak256(abi.encode(reader, subject))] = true;
        emit Settled(subject, nullifier, reader);
    }

    // ── Reads ─────────────────────────────────────────────────────────────────

    function groupOf(bytes32 subject) public view returns (uint256) {
        uint256 g = groups[subject];
        if (g == 0) revert NoGroup();
        return g - 1;
    }

    function isRegistered(bytes32 subject, uint256 commitment) external view returns (bool) {
        return registered[keccak256(abi.encode(subject, commitment))];
    }

    function isSettled(address reader, bytes32 subject) public view returns (bool) {
        return settled[keccak256(abi.encode(reader, subject))];
    }

    /// Whether `reader` may read record `key` of the repo: settled for the record or the
    /// whole repo, and neither is disabled.
    function canRead(address reader, address publisher, bytes32 repo, bytes32 key) external view returns (bool) {
        bytes32 whole = subjectOf(publisher, repo, bytes32(0));
        bytes32 one = subjectOf(publisher, repo, key);
        if (isDisabled[whole] || isDisabled[one]) return false;
        return isSettled(reader, whole) || isSettled(reader, one);
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
