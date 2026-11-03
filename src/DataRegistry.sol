// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// DataRegistry
///
/// The heads of every repo, and their update log.
///
/// A repo is `(publisher, repo)`: one publisher's data under a name it chooses. An update
/// moves it from `parent` to the commit `(epoch, parent, root, repo, car)`, whose head this
/// contract computes: the sha256 digest of the commit's dag-cbor block. `parent` and
/// `root` are digests of dag-cbor blocks, `car` is a whole CID. The epoch must lie within
/// `WINDOW` epochs of the current one.
///
/// `updateBySig` takes the publisher's EIP-712 signature, so anyone may submit it. The
/// parent check is its replay protection.
///
/// The update log is a Merkle mountain range kept as its peaks: leaf
/// keccak256(abi.encode("leaf", publisher, repo_id, pos, head, timestamp)), inner node
/// keccak256(abi.encode("node", left, right)), root
/// keccak256(abi.encode("mmr", length, peaks from highest to lowest)).
///
/// Deployed behind an ERC-1967 proxy (UUPS). Storage is append-only.
contract DataRegistry is Initializable, UUPSUpgradeable {
    error Unauthorized();
    error StaleStateRoot();
    error EpochOutOfWindow();
    error BadSignature();

    event AdminChanged(address previous_admin, address new_admin);
    /// `publisher` moved `repo` from `parent` to `head`, the repo's `pos`-th head.
    event Updated(
        address indexed publisher, bytes32 indexed repo_id, string repo, uint64 pos, bytes32 parent, bytes32 head
    );

    struct Head {
        uint64 pos;
        bytes32 head;
    }

    uint64 public constant EPOCH_SECONDS = 3600;
    uint64 public constant WINDOW = 24;

    bytes32 public constant UPDATE_TYPEHASH =
        keccak256("Update(address publisher,string repo,uint64 epoch,bytes32 parent,bytes32 root,bytes car)");
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

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

    // ── Updates ───────────────────────────────────────────────────────────────

    function update(string calldata repo, uint64 epoch, bytes32 parent, bytes32 root, bytes calldata car)
        external
        returns (bytes32)
    {
        return _update(msg.sender, repo, epoch, parent, root, car);
    }

    function updateBySig(
        address publisher,
        string calldata repo,
        uint64 epoch,
        bytes32 parent,
        bytes32 root,
        bytes calldata car,
        bytes calldata signature
    ) external returns (bytes32) {
        bytes32 digest = MessageHashUtils.toTypedDataHash(
            domainSeparator(),
            keccak256(
                abi.encode(UPDATE_TYPEHASH, publisher, keccak256(bytes(repo)), epoch, parent, root, keccak256(car))
            )
        );
        if (!SignatureChecker.isValidSignatureNow(publisher, digest, signature)) revert BadSignature();
        return _update(publisher, repo, epoch, parent, root, car);
    }

    function _update(
        address publisher,
        string calldata repo,
        uint64 epoch,
        bytes32 parent,
        bytes32 root,
        bytes calldata car
    ) private returns (bytes32 head) {
        uint64 now_ = currentEpoch();
        if (epoch > now_ || epoch + WINDOW < now_) revert EpochOutOfWindow();

        bytes32 repo_id = keccak256(bytes(repo));
        Head storage h = heads[publisher][repo_id];
        if (h.head != parent) revert StaleStateRoot();
        if (h.pos == 0) repoIds[publisher].push(repo_id);

        head = commitHead(repo, epoch, parent, root, car);
        uint64 pos = h.pos + 1;
        h.pos = pos;
        h.head = head;
        _append(keccak256(abi.encode(LEAF, publisher, repo_id, pos, head, uint64(block.timestamp))));
        emit Updated(publisher, repo_id, repo, pos, parent, head);
    }

    // ── Commits ───────────────────────────────────────────────────────────────

    /// The head of commit `(epoch, parent, root, repo, car)`. Zero `parent`: a root commit.
    function commitHead(string calldata repo, uint64 epoch, bytes32 parent, bytes32 root, bytes calldata car)
        public
        pure
        returns (bytes32)
    {
        // dag-cbor map, keys in canonical order: car, repo, root, epoch, parent
        return sha256(
            abi.encodePacked(
                hex"a5",
                hex"63636172",
                _link(car),
                hex"647265706f",
                _cborHead(3, bytes(repo).length),
                repo,
                hex"64726f6f74",
                _link(_dagCborCid(root)),
                hex"6565706f6368",
                _cborHead(0, epoch),
                hex"66706172656e74",
                parent == bytes32(0) ? bytes(hex"f6") : _link(_dagCborCid(parent))
            )
        );
    }

    // forge-lint: disable-next-item(unsafe-typecast)
    function _cborHead(uint8 major, uint256 n) private pure returns (bytes memory) {
        bytes1 m = bytes1(major << 5);
        if (n < 24) return abi.encodePacked(m | bytes1(uint8(n)));
        if (n < 1 << 8) return abi.encodePacked(m | bytes1(0x18), uint8(n));
        if (n < 1 << 16) return abi.encodePacked(m | bytes1(0x19), uint16(n));
        if (n < 1 << 32) return abi.encodePacked(m | bytes1(0x1a), uint32(n));
        return abi.encodePacked(m | bytes1(0x1b), uint64(n));
    }

    /// CBOR tag 42: a CID link.
    function _link(bytes memory cid) private pure returns (bytes memory) {
        return abi.encodePacked(hex"d82a", _cborHead(2, cid.length + 1), hex"00", cid);
    }

    /// CIDv1, dag-cbor, sha256.
    function _dagCborCid(bytes32 digest) private pure returns (bytes memory) {
        return abi.encodePacked(hex"01711220", digest);
    }

    // ── Log ───────────────────────────────────────────────────────────────────

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

    // ── Reads ─────────────────────────────────────────────────────────────────

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

    // ── Admin ─────────────────────────────────────────────────────────────────

    /// The admin is also who may upgrade this contract, so setting zero renounces both.
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
