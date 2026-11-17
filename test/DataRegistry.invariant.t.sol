// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DataRegistry} from "../src/DataRegistry.sol";
import {Proxied} from "./Mocks.sol";

bytes32 constant DIFF = 0x1111111111111111111111111111111111111111111111111111111111111111;
bytes32 constant ROOT = 0xc3a75f27a0777dd37f80e7252ba50f882a088dd9b6e3e602281b9c217375cd9f;
bytes constant CAR = hex"01551220039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81";

/// Drives the registry with valid and invalid updates and keeps an independent model:
/// per-repo positions and heads, and every log leaf, from which the mountain range root
/// is rebuilt recursively (not incrementally, as the contract does).
contract DataHandler is Test {
    DataRegistry public reg;
    address[3] public pubs;
    uint256[3] internal keys;
    string[3] internal repos = ["photos", "", "a repo name longer than twenty-three bytes"];

    bytes32[] public leaves;
    mapping(address => mapping(bytes32 => uint64)) public pos;
    mapping(address => mapping(bytes32 => bytes32)) public head;
    /// set when a call's outcome differs from what the model predicts
    string public violation;

    constructor(DataRegistry reg_) {
        reg = reg_;
        for (uint256 i; i < 3; i++) {
            (pubs[i], keys[i]) = makeAddrAndKey(string.concat("pub", vm.toString(i)));
        }
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 3 days));
    }

    /// `back` picks the epoch: now - back for back <= 26, now + 1 above it. A signed update
    /// is sent by an arbitrary relayer (derived from `diff`).
    function update(uint256 p, uint256 r, uint256 back, uint8 staleSeed, bool bySig, bytes32 diff) public {
        bool stale = staleSeed % 4 == 0;
        p = bound(p, 0, 2);
        string memory repo = repos[bound(r, 0, 2)];
        back = bound(back, 0, 27);
        uint64 now_ = reg.currentEpoch();
        uint64 epoch = back > 26 ? now_ + 1 : now_ - uint64(back);
        bytes32 parent = head[pubs[p]][keccak256(bytes(repo))];
        if (stale) parent = keccak256(abi.encode(parent, diff)); // never the head
        bool ok = !stale && back <= 24;
        bool success = bySig ? _bySig(p, repo, epoch, parent, diff) : _direct(p, repo, epoch, parent, diff);
        if (success != ok) violation = success ? "invalid update accepted" : "valid update rejected";
    }

    /// Several valid updates in a row, so the log grows past a few carries.
    function burst(uint256 p, uint256 r, uint8 n, bytes32 diff) external {
        (p, r) = (bound(p, 0, 2), bound(r, 0, 2));
        for (uint256 i; i < bound(n, 1, 16); i++) {
            update(p + i, r + i / 3, 0, 1, i % 2 == 0, keccak256(abi.encode(diff, i)));
        }
    }

    function _direct(uint256 p, string memory repo, uint64 epoch, bytes32 parent, bytes32 diff)
        internal
        returns (bool)
    {
        vm.prank(pubs[p]);
        try reg.update(repo, epoch, parent, diff, ROOT, CAR) returns (bytes32 h) {
            _record(pubs[p], repo, h);
            return true;
        } catch {
            return false;
        }
    }

    function _bySig(uint256 p, string memory repo, uint64 epoch, bytes32 parent, bytes32 diff) internal returns (bool) {
        bytes memory sig = _sign(keys[p], pubs[p], repo, epoch, parent, diff);
        vm.prank(address(uint160(uint256(diff)) | 1));
        try reg.updateBySig(pubs[p], repo, epoch, parent, diff, ROOT, CAR, sig) returns (bytes32 h) {
            _record(pubs[p], repo, h);
        } catch {
            return false;
        }
        // A signed update lands once: the same signature again names a stale parent.
        try reg.updateBySig(pubs[p], repo, epoch, parent, diff, ROOT, CAR, sig) {
            violation = "updateBySig replayed";
        } catch {}
        return true;
    }

    function _record(address pub, string memory repo, bytes32 h) internal {
        bytes32 id = keccak256(bytes(repo));
        uint64 n = ++pos[pub][id];
        head[pub][id] = h;
        leaves.push(keccak256(abi.encode(bytes32("leaf"), pub, id, n, h, uint64(block.timestamp))));
    }

    /// A signature by the wrong key never moves anyone's repo.
    function forged(uint256 p, uint256 wrong, uint256 r) external {
        p = bound(p, 0, 2);
        wrong = (p + 1 + bound(wrong, 0, 1)) % 3;
        string memory repo = repos[bound(r, 0, 2)];
        uint64 epoch = reg.currentEpoch();
        bytes32 parent = head[pubs[p]][keccak256(bytes(repo))];
        bytes memory sig = _sign(keys[wrong], pubs[p], repo, epoch, parent, DIFF);
        try reg.updateBySig(pubs[p], repo, epoch, parent, DIFF, ROOT, CAR, sig) {
            violation = "forged signature accepted";
        } catch {}
    }

    function _sign(uint256 key, address pub, string memory repo, uint64 epoch, bytes32 parent, bytes32 diff)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(reg.UPDATE_TYPEHASH(), pub, keccak256(bytes(repo)), epoch, parent, diff, ROOT, keccak256(CAR))
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(key, keccak256(abi.encodePacked("\x19\x01", reg.domainSeparator(), structHash)));
        return abi.encodePacked(r, s, v);
    }

    // ── model reads ──

    function leafCount() external view returns (uint256) {
        return leaves.length;
    }

    function repoAt(uint256 i) external view returns (string memory) {
        return repos[i];
    }

    /// H(MMR, n, peaks tallest first), each peak the root of a perfect tree over its leaves.
    function modelRoot() external view returns (bytes32) {
        uint256 n = leaves.length;
        bytes32[] memory live = new bytes32[](_popcount(n));
        uint256 start;
        uint256 k;
        for (uint256 h = 64; h > 0; h--) {
            uint256 size = 1 << (h - 1);
            if (n & size != 0) {
                live[k++] = _tree(start, size);
                start += size;
            }
        }
        return keccak256(abi.encode(bytes32("mmr"), n, live));
    }

    function _tree(uint256 start, uint256 size) internal view returns (bytes32) {
        if (size == 1) return leaves[start];
        return keccak256(abi.encode(bytes32("node"), _tree(start, size / 2), _tree(start + size / 2, size / 2)));
    }

    function _popcount(uint256 n) internal pure returns (uint256 c) {
        for (; n != 0; n &= n - 1) {
            c++;
        }
    }
}

/// Stateful properties of the DataRegistry. Runs/depth are in foundry.toml [invariant];
/// a longer campaign: FOUNDRY_INVARIANT_RUNS=2000 FOUNDRY_INVARIANT_DEPTH=200 forge test --mc Invariant
contract DataRegistryInvariantTest is Test {
    DataRegistry reg;
    DataHandler handler;

    function setUp() public {
        vm.warp(493_001 * 3600 + 5);
        reg = Proxied.dataRegistry(address(0xAD));
        handler = new DataHandler(reg);
        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](4);
        sel[0] = DataHandler.warp.selector;
        sel[1] = DataHandler.update.selector;
        sel[2] = DataHandler.forged.selector;
        sel[3] = DataHandler.burst.selector;
        targetSelector(FuzzSelector(address(handler), sel));
    }

    function invariant_every_outcome_matches_the_model() public view {
        assertEq(handler.violation(), "");
    }

    function invariant_log_length_counts_successful_updates() public view {
        assertEq(reg.logLength(), handler.leafCount());
    }

    function invariant_log_root_matches_reference_mmr() public view {
        assertEq(reg.logRoot(), handler.modelRoot());
    }

    function invariant_heads_and_positions_match_the_model() public view {
        for (uint256 p; p < 3; p++) {
            address pub = handler.pubs(p);
            for (uint256 r; r < 3; r++) {
                bytes32 id = keccak256(bytes(handler.repoAt(r)));
                (uint64 pos, bytes32 h) = reg.getHead(pub, id);
                assertEq(pos, handler.pos(pub, id));
                assertEq(h, handler.head(pub, id));
            }
        }
    }

    /// repoIds lists exactly the written repos, each once.
    function invariant_repo_ids_are_exactly_the_written_repos() public view {
        for (uint256 p; p < 3; p++) {
            address pub = handler.pubs(p);
            uint256 written;
            for (uint256 r; r < 3; r++) {
                if (handler.pos(pub, keccak256(bytes(handler.repoAt(r)))) > 0) written++;
            }
            uint256 n = reg.repoCount(pub);
            assertEq(n, written);
            for (uint256 i; i < n; i++) {
                bytes32 id = reg.repoIds(pub, i);
                assertGt(handler.pos(pub, id), 0);
                for (uint256 j; j < i; j++) {
                    assertTrue(reg.repoIds(pub, j) != id, "duplicate repo id");
                }
            }
        }
    }
}

/// Stateless fuzz: the epoch window and the commit encoding.
contract DataRegistryFuzzTest is Test {
    DataRegistry reg;
    address constant PUB = address(0xB0B);

    function setUp() public {
        reg = Proxied.dataRegistry(address(0xAD));
    }

    function _try(string memory repo, uint64 epoch, bytes32 parent) internal returns (bool ok) {
        vm.prank(PUB);
        try reg.update(repo, epoch, parent, DIFF, ROOT, CAR) {
            ok = true;
        } catch {}
    }

    /// Accepted exactly for epochs in [now - 24, now], at any time.
    function testFuzz_epoch_window_boundaries(uint256 ts) public {
        ts = bound(ts, 25 * 3600, type(uint64).max / 2);
        vm.warp(ts);
        uint64 now_ = reg.currentEpoch();
        assertFalse(_try("a", now_ + 1, 0), "future epoch");
        assertFalse(_try("a", now_ - 25, 0), "epoch older than the window");
        assertTrue(_try("a", now_ - 24, 0), "oldest epoch in the window");
        assertTrue(_try("b", now_, 0), "current epoch");
    }

    /// A stale parent reverts and leaves the head and the log untouched.
    function testFuzz_stale_parent_changes_nothing(bytes32 bad, uint8 writes) public {
        vm.warp(493_001 * 3600);
        bytes32 h;
        uint64 e = reg.currentEpoch();
        for (uint256 i; i < bound(writes, 1, 5); i++) {
            vm.prank(PUB);
            h = reg.update("r", e, h, DIFF, ROOT, CAR);
        }
        vm.assume(bad != h);
        bytes32 root = reg.logRoot();
        uint64 len = reg.logLength();
        (uint64 pos,) = reg.getHead(PUB, keccak256("r"));
        assertFalse(_try("r", reg.currentEpoch(), bad));
        (uint64 pos2, bytes32 h2) = reg.getHead(PUB, keccak256("r"));
        assertEq(pos2, pos);
        assertEq(h2, h);
        assertEq(reg.logLength(), len);
        assertEq(reg.logRoot(), root);
    }

    // ── commitHead: known answers from @ipld/dag-cbor (test/ffi/commitHead.mjs) at every
    //    step of the CBOR length ladder (n < 24, < 2^8, < 2^16, < 2^32, else) ──

    bytes32 constant PARENT = 0x96e5fb518a2070784f5c2920494d35c7585a7c3ebf0e11c48138ff607d4f499f;

    function _rep(bytes1 b, uint256 n) internal pure returns (bytes memory s) {
        s = new bytes(n);
        for (uint256 i; i < n; i++) {
            s[i] = b;
        }
    }

    /// repo = n x "r", epoch 493000, parent PARENT
    function test_commitHead_repo_length_ladder() public view {
        uint256[7] memory n = [uint256(0), 23, 24, 255, 256, 65535, 65536];
        bytes32[7] memory want = [
            bytes32(0x0bbe86fa3f8e0fb2b70090bf06b215a55a25b521debc0286b5909218c16af6d1),
            0x0fd174684cc2796da000b15fdaeeb2bcae6f3bc8d493ceb7282fbaaf9fc5bbcf,
            0xb4a48bc6bf3f9127acf51ef8009a5acae1560335b51aadc4a7efbef4f98dfdcb,
            0x41941a648ac161e17ae9bc68d62f5181281ec7b756e8d6a54dfe772a92657784,
            0x68147263f5611dd393d2112922c031243df9b98b0070797628348854a485a1bd,
            0xc4949a88754dc7b0be9f5084871526705c02ddd624f6e7ee78000bdc9d7be752,
            0xd22316b790a29f3386ab4e2cd4c07f362d6fa8783b8b01f8286f245f16ea1db8
        ];
        for (uint256 i; i < n.length; i++) {
            assertEq(_head(string(_rep("r", n[i])), 493000, PARENT, CAR), want[i]);
        }
    }

    /// repo "photos", no parent
    function test_commitHead_epoch_ladder() public view {
        uint64[10] memory e = [uint64(0), 23, 24, 255, 256, 65535, 65536, 2 ** 32 - 1, 2 ** 32, type(uint64).max];
        bytes32[10] memory want = [
            bytes32(0x385902b70253bf505e99002dda9f67a09f628f95b65891f5c8754cf3cc0a90e2),
            0x34f8d8ae2a134ae69d07b9eb75b24274c26fa4a111025b909b5f479a63d05326,
            0x668627ec045b3ac5d20c3597daa8be49fd90dea0efc550ed2254c244f8dc8dae,
            0xb85d9cc6df50d9abbe7edf58bf523dae7a8edd00da864e596fa9a068f728ab4f,
            0x15b519ecfd539630090c79d09cda4969b30ae97dbd7771e5948556ebe6340842,
            0xb942050a94d2028590f2b4f618eb6f7d29918e63cbade88fd719e51c45d8af5a,
            0x6f4d8d6d06c67e8c19a50ae93843fbe09cdb43c9183a1ebd52c0697f7f05961c,
            0x7ede98b7c24a49b67a22652677752b38f539a5c62263417f4182b5e13317c97e,
            0x9cbee4a5629a03986751abafe4bf2253aa6c1db1e595a7a745b7c76c4ac0af23,
            0x776f51ea7bd66aca4e3005daaf3a6fa82ec2e38faed2daca9c31f27f9a4c5fc2
        ];
        for (uint256 i; i < e.length; i++) {
            assertEq(_head("photos", e[i], 0, CAR), want[i]);
        }
    }

    /// car = identity-multihash CID (01 55 00 varint(n) n x ab), so the link's byte string
    /// (0x00 ++ cid) is 23, 24, 255, 256, 65535, 65536 bytes long. repo "photos", no parent.
    function test_commitHead_car_length_ladder() public view {
        uint256[6] memory n = [uint256(18), 19, 249, 250, 65528, 65529];
        bytes32[6] memory want = [
            bytes32(0x5b0676820f629b8de08d6c058032b3d446b0afacb4b47990fb59b3d0cc5e1271),
            0x21b81bb946c9b1904da8b305eb72ebc53b0a0b528026190ba9302b6dcfb13d84,
            0x5a4effcb50165305abf17c94b2a084cdcf6908fa3ea39e16d49231c9dfc8fbb5,
            0xd2fd9cb6c52bebfd69cd7fc41f0bd65e3baed90bf04a9cc01f8ea57723c8ac59,
            0x60701d59f6996d81da3143411404c992d246fd146b56ffc5b1864096408531d9,
            0x8d3dd05ca7a351a42b78e53addac1c7daf60208bca9c32aa890d2f6a76c59075
        ];
        for (uint256 i; i < n.length; i++) {
            assertEq(_head("photos", 493000, 0, _identityCid(n[i])), want[i]);
        }
    }

    function _identityCid(uint256 n) internal pure returns (bytes memory) {
        bytes memory v;
        for (uint256 x = n;;) {
            if (x >> 7 == 0) {
                v = abi.encodePacked(v, uint8(x));
                break;
            }
            v = abi.encodePacked(v, uint8(x & 0x7f) | 0x80);
            x >>= 7;
        }
        return abi.encodePacked(hex"015500", v, _rep(0xab, n));
    }

    function _head(string memory repo, uint64 epoch, bytes32 parent, bytes memory car) internal view returns (bytes32) {
        return reg.commitHead(repo, epoch, parent, DIFF, ROOT, car);
    }

    /// The registry hashes whatever it is given: a `car` that is not a CID, or a repo name
    /// that is not UTF-8, still moves the head, though no DAG-CBOR library can produce or
    /// decode that commit block (see the ffi test). Pinned here so a change is deliberate.
    function test_commitHead_accepts_inputs_with_no_dag_cbor_form() public {
        vm.warp(493_001 * 3600);
        uint64 e = reg.currentEpoch();
        vm.startPrank(PUB);
        reg.update("photos", e, 0, DIFF, ROOT, ""); // empty car
        reg.update(string(bytes(hex"ff")), e, 0, DIFF, ROOT, CAR); // not UTF-8
        vm.stopPrank();
        (uint64 a,) = reg.getHead(PUB, keccak256("photos"));
        (uint64 b,) = reg.getHead(PUB, keccak256(hex"ff"));
        assertEq(a + b, 2);
    }

    // ── differential fuzz against @ipld/dag-cbor (opt-in: needs Node.js and the SDK's
    //    node_modules). DAG_CBOR_NODE_MODULES=../fangorn/node_modules forge test --mt Ipld ──

    function _ipld(string memory repo, uint64 epoch, bytes32 parent, bytes32 diff, bytes32 root, bytes memory car)
        internal
        returns (bytes memory)
    {
        string memory nm = vm.envOr("DAG_CBOR_NODE_MODULES", string(""));
        if (bytes(nm).length == 0) vm.skip(true);
        string[] memory cmd = new string[](9);
        cmd[0] = "node";
        cmd[1] = "test/ffi/commitHead.mjs";
        cmd[2] = nm;
        cmd[3] = vm.toString(bytes(repo));
        cmd[4] = vm.toString(epoch);
        cmd[5] = vm.toString(parent);
        cmd[6] = vm.toString(diff);
        cmd[7] = vm.toString(root);
        cmd[8] = vm.toString(car);
        return vm.ffi(cmd);
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_commitHead_matches_Ipld(
        string memory repo,
        uint64 epoch,
        bytes32 parent,
        bytes32 diff,
        bytes32 root,
        bytes32 digest,
        uint8 kind
    ) public {
        bytes memory car = kind % 4 == 0
            ? abi.encodePacked(hex"01551220", digest)  // CIDv1 raw
            : kind % 4 == 1
                ? abi.encodePacked(hex"01711220", digest)  // CIDv1 dag-cbor
                : kind % 4 == 2 ? abi.encodePacked(hex"1220", digest) : _identityCid(kind % 100); // CIDv0, identity
        bytes memory want = _ipld(repo, epoch, parent, diff, root, car);
        vm.assume(want.length == 32); // repo not UTF-8: no DAG-CBOR form
        assertEq(reg.commitHead(repo, epoch, parent, diff, root, car), bytes32(want));
    }

    function test_commitHead_inputs_with_no_dag_cbor_form_Ipld() public {
        assertEq(_ipld("photos", 1, 0, DIFF, ROOT, "").length, 0, "empty car");
        assertEq(_ipld("photos", 1, 0, DIFF, ROOT, hex"0155").length, 0, "truncated CID");
        assertEq(_ipld(string(bytes(hex"ff")), 1, 0, DIFF, ROOT, CAR).length, 0, "repo not UTF-8");
    }
}
