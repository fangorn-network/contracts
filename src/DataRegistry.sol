// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// # DataRegistry
///
/// The data registry enables version-control and tracking for generic data repositories.
///
/// A repo, identified by `(publisher, repo_name)`, is a single-publisher [Merkle clock](https://research.protocol.ai/publications/merkle-crdts-merkle-dags-meet-crdts/psaras2020.pdf).
/// This contract is responsible for computing and tracking updated repo heads (committments to the latest state)
///
/// Deployed behind an ERC-1967 proxy (UUPS). Storage is append-only.
contract DataRegistry is Initializable, UUPSUpgradeable {
    error Unauthorized();
    error StaleStateRoot();
    error EpochOutOfWindow();
    error BadSignature();

    event AdminChanged(address previous_admin, address new_admin);
    /// a `publisher` updated a `repo` from `parent` to `head`, the repo's `pos`-th head.
    event Updated(
        address indexed publisher, bytes32 indexed repo_id, string repo, uint64 pos, bytes32 parent, bytes32 head
    );

    // the latest (pos, commitment) for a repo
    struct Head {
        // the position of the head (e.g. the `pos`-th udpate)
        uint64 pos;
        // the `pos`-th head commitment (merkle clock root)
        bytes32 head;
    }

    // 1 hour
    uint64 public constant EPOCH_SECONDS = 3600;
    // 24 hours - signed updates expire after this timeframe
    uint64 public constant WINDOW = 24;

    // constant for EIP-712 signed updates
    bytes32 public constant UPDATE_TYPEHASH = keccak256(
        "Update(address publisher,string repo,uint64 epoch,bytes32 parent,bytes32 diff,bytes32 root,bytes car)"
    );
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    // MMR domain tags; see "Log (Merkle Mountain Range)" below
    bytes32 private constant LEAF = "leaf";
    bytes32 private constant NODE = "node";
    bytes32 private constant MMR = "mmr";

    address public admin;
    /// publisher => keccak256(repo) => (position, head); (0, 0) for a repo never written
    mapping(address => mapping(bytes32 => Head)) internal heads;
    uint64 public logLength;
    /// height => peak; live where `logLength` has that bit set
    mapping(uint256 => bytes32) public peaks;
    /// publisher => repo ids, in the order first written
    mapping(address => bytes32[]) public repoIds;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin_) external initializer {
        admin = admin_;
    }

    // Update a repo state
    //
    // For the caller's repo named `repo`, update the previous state, identified by parent, 
    // by applying a diff, identified by its content identifier, and the root of the new Merkle clock
    //
    function update(string calldata repo, uint64 epoch, bytes32 parent, bytes32 diff, bytes32 root, bytes calldata car)
        external
        returns (bytes32)
    {
        return _update(msg.sender, repo, epoch, parent, diff, root, car);
    }

    function updateBySig(
        address publisher,
        string calldata repo,
        uint64 epoch,
        bytes32 parent,
        bytes32 diff,
        bytes32 root,
        bytes calldata car,
        bytes calldata signature
    ) external returns (bytes32) {
        bytes32 digest = MessageHashUtils.toTypedDataHash(
            domainSeparator(),
            keccak256(
                abi.encode(
                    UPDATE_TYPEHASH, publisher, keccak256(bytes(repo)), epoch, parent, diff, root, keccak256(car)
                )
            )
        );
        if (!SignatureChecker.isValidSignatureNow(publisher, digest, signature)) revert BadSignature();
        return _update(publisher, repo, epoch, parent, diff, root, car);
    }

    function _update(
        address publisher,
        string calldata repo,
        uint64 epoch,
        bytes32 parent,
        bytes32 diff,
        bytes32 root,
        bytes calldata car
    ) private returns (bytes32 head) {
        uint64 now_ = currentEpoch();
        if (epoch > now_ || epoch + WINDOW < now_) revert EpochOutOfWindow();

        bytes32 repo_id = keccak256(bytes(repo));
        Head storage h = heads[publisher][repo_id];
        if (h.head != parent) revert StaleStateRoot();
        if (h.pos == 0) repoIds[publisher].push(repo_id);

        head = commitHead(repo, epoch, parent, diff, root, car);
        uint64 pos = h.pos + 1;
        h.pos = pos;
        h.head = head;
        _append(keccak256(abi.encode(LEAF, publisher, repo_id, pos, head, uint64(block.timestamp))));
        emit Updated(publisher, repo_id, repo, pos, parent, head);
    }

    // ── Commits ───────────────────────────────────────────────────────────────

    /// The head of commit `(epoch, parent, diff, root, repo, car)`. Zero `parent`: a root commit.
    ///
    /// The commit is serialized by hand as a DAG-CBOR (IPLD) map and hashed with sha256, so the
    /// returned head is exactly the digest an IPFS/IPLD library would produce for the block
    ///   { car: CID, diff: CID, repo: string, root: CID, epoch: uint, parent: CID | null }
    /// i.e. `CIDv1(dag-cbor, sha256(head))` addresses the commit off-chain. `parent` points at
    /// the previous commit block, which is what makes the chain of heads a Merkle clock.
    ///
    /// CBOR primer: every item starts with one byte, `major type << 5 | info` (see `_cborHead`).
    function commitHead(string memory repo, uint64 epoch, bytes32 parent, bytes32 diff, bytes32 root, bytes memory car)
        public
        pure
        returns (bytes32)
    {
        // DAG-CBOR requires map keys sorted by length, then bytewise:
        // car(3) < diff(4) < repo(4) < root(4) < epoch(5) < parent(6)
        // `car` is already raw CID bytes; the other links are dag-cbor sha256 digests.
        // forgefmt: disable-start
        // two halves only to stay under the EVM's 16-slot stack limit
        bytes memory firstHalf = abi.encodePacked(
            _cborHead(MAP, 6),
            _entry("car",    _link(car)),
            _entry("diff",   _link(_dagCborCid(diff))),
            _entry("repo",   _text(repo))
        );
        return sha256(abi.encodePacked(
            firstHalf,
            _entry("root",   _link(_dagCborCid(root))),
            _entry("epoch",  _cborHead(UINT, epoch)),
            _entry("parent", parent == bytes32(0) ? CBOR_NULL : _link(_dagCborCid(parent)))
        ));
        // forgefmt: disable-end
    }

    // CBOR major types (the top 3 bits of an item's first byte)
    uint8 private constant UINT = 0;
    uint8 private constant BYTES = 2;
    uint8 private constant TEXT = 3;
    uint8 private constant MAP = 5;
    // major 7, simple value 22
    bytes private constant CBOR_NULL = hex"f6";

    /// One map entry: text key followed by an already-encoded value.
    function _entry(string memory key, bytes memory value) private pure returns (bytes memory) {
        return abi.encodePacked(_text(key), value);
    }

    /// A CBOR text string: header (major 3, byte length) followed by the utf-8 bytes.
    function _text(string memory s) private pure returns (bytes memory) {
        return abi.encodePacked(_cborHead(TEXT, bytes(s).length), s);
    }

    /// CBOR item header: top 3 bits = major type, low 5 bits = "additional info".
    /// For uints `n` is the value itself; for strings it is the length in bytes.
    ///   n < 24      -> packed into the low 5 bits (one byte total)
    ///   info 0x18   -> n follows as 1 byte    (24 = "uint8 follows")
    ///   info 0x19   -> n follows as 2 bytes   (25 = "uint16 follows")
    ///   info 0x1a   -> n follows as 4 bytes   (26 = "uint32 follows")
    ///   info 0x1b   -> n follows as 8 bytes   (27 = "uint64 follows")
    /// CBOR is big-endian, which is what `abi.encodePacked(uintN)` emits. DAG-CBOR also requires
    /// the shortest form, hence the ladder.
    // forge-lint: disable-next-item(unsafe-typecast)
    function _cborHead(uint8 major, uint256 n) private pure returns (bytes memory) {
        bytes1 m = bytes1(major << 5);
        if (n < 24) return abi.encodePacked(m | bytes1(uint8(n)));
        if (n < 1 << 8) return abi.encodePacked(m | bytes1(0x18), uint8(n));
        if (n < 1 << 16) return abi.encodePacked(m | bytes1(0x19), uint16(n));
        if (n < 1 << 32) return abi.encodePacked(m | bytes1(0x1a), uint32(n));
        return abi.encodePacked(m | bytes1(0x1b), uint64(n));
    }

    /// A DAG-CBOR CID link: CBOR tag 42 wrapping a byte string of `0x00 ++ cid`.
    ///   0xd8 0x2a -> tag (major 6 = 0xc0, info 0x18 = "1-byte tag follows"), tag number 42
    ///   0x00      -> multibase "identity" prefix the DAG-CBOR spec mandates inside tag 42
    function _link(bytes memory cid) private pure returns (bytes memory) {
        return abi.encodePacked(hex"d82a", _cborHead(BYTES, cid.length + 1), hex"00", cid);
    }

    /// Binary CID for a dag-cbor block with the given sha256 digest:
    ///   0x01 CIDv1 | 0x71 codec dag-cbor | 0x12 multihash sha2-256 | 0x20 digest length (32)
    function _dagCborCid(bytes32 digest) private pure returns (bytes memory) {
        return abi.encodePacked(hex"01711220", digest);
    }

    // ── Log (Merkle Mountain Range) ───────────────────────────────────────────
    //
    // Every successful update, by any publisher, appends one leaf
    //   keccak256(LEAF, publisher, repo_id, pos, head, timestamp)
    // to a single global, append-only log. `logRoot()` commits to the whole log, so a client
    // holding a root can be given a short inclusion proof that a given head was published at a
    // given position and time, without trusting an indexer.
    //
    // The log is a Merkle Mountain Range: a list of perfect binary trees ("peaks") of strictly
    // decreasing height. With n leaves there is one peak of height h for each set bit h of n
    // (e.g. n = 6 = 0b110 -> peaks of 4 and 2 leaves). Appending works like binary increment:
    // the new leaf merges with the peak of each trailing 1-bit (the carries) and lands at the
    // first 0-bit. That is O(log n) storage writes and no array of leaves on chain.
    // `peaks[h]` is only meaningful while bit h of `logLength` is set; stale slots are left
    // behind and overwritten later.
    //
    // LEAF / NODE / MMR are domain tags so a leaf hash can never be passed off as an inner node
    // or a root (second-preimage protection).

    /// Append `leaf`, merging equal-height peaks (the binary "carry").
    function _append(bytes32 leaf) private {
        uint64 n = logLength;
        bytes32 node = leaf;
        uint256 height;
        while ((n >> height) & 1 == 1) {
            node = keccak256(abi.encode(NODE, peaks[height], node));
            height++;
        }
        peaks[height] = node;
        logLength = n + 1;
    }

    /// Commitment to the whole log: H(MMR, length, live peaks from tallest to shortest).
    function logRoot() external view returns (bytes32) {
        uint64 n = logLength;
        bytes32[] memory live = new bytes32[](_popcount(n));
        uint256 i;
        for (uint256 height = 64; height > 0; height--) {
            if ((n >> (height - 1)) & 1 == 1) live[i++] = peaks[height - 1];
        }
        return keccak256(abi.encode(MMR, n, live));
    }

    function _popcount(uint64 n) private pure returns (uint256 c) {
        for (; n != 0; n &= n - 1) {
            c++;
        }
    }

    // read only functions

    /// H(publisher, repo): its position and head, (0, 0) if never written.
    function getHead(address publisher, bytes32 repo_id) external view returns (uint64 pos, bytes32 head) {
        Head storage h = heads[publisher][repo_id];
        return (h.pos, h.head);
    }

    function repoCount(address publisher) external view returns (uint256) {
        return repoIds[publisher].length;
    }

    function currentEpoch() public view returns (uint64) {
        return uint64(block.timestamp / EPOCH_SECONDS);
    }

    function domainSeparator() public view returns (bytes32) {
        return
            keccak256(
                abi.encode(DOMAIN_TYPEHASH, keccak256("Fangorn Data"), keccak256("1"), block.chainid, address(this))
            );
    }

    //  admin functions

    // as the current admin, set a new one
    // TODO: this should be a 'propose' and 'accept' instead (new admin must accept the role, is cancellable, etc)
    function setAdmin(address new_admin) external onlyAdmin {
        emit AdminChanged(admin, new_admin);
        admin = new_admin;
    }

    function _authorizeUpgrade(address) internal override onlyAdmin {}

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Unauthorized();
        _;
    }
}
