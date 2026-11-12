// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DataRegistry} from "../src/DataRegistry.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Proxied} from "./Mocks.sol";

/// What an upgrade installs: the same contract, plus one function to tell it by.
contract DataRegistryUpgradeMock is DataRegistry {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// An ERC-1271 wallet that accepts one digest.
contract DataWallet {
    bytes32 public approved;

    function approve(bytes32 digest) external {
        approved = digest;
    }

    function isValidSignature(bytes32 digest, bytes calldata) external view returns (bytes4) {
        return digest == approved ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

/// The DataRegistry on its own: it calls nothing.
contract DataRegistryTest is Test {
    address constant ADMIN = 0x1111111111111111111111111111111111111111;
    address constant PUB = 0x2222222222222222222222222222222222222222;

    // Commits encoded by the SDK (`encodeBlock` in src/engine/records.ts): an empty MST
    // root, a diff of 0x11.., and a raw CID of the bytes 0x010203 as the CAR.
    bytes32 constant ROOT = 0xc3a75f27a0777dd37f80e7252ba50f882a088dd9b6e3e602281b9c217375cd9f;
    bytes32 constant DIFF = 0x1111111111111111111111111111111111111111111111111111111111111111;
    bytes constant CAR = hex"01551220039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81";
    uint64 constant E = 493_000;
    /// (E, no parent, DIFF, ROOT, "photos", CAR)
    bytes32 constant FIRST = 0x96e5fb518a2070784f5c2920494d35c7585a7c3ebf0e11c48138ff607d4f499f;
    /// (E + 1, FIRST, DIFF, ROOT, "photos", CAR)
    bytes32 constant SECOND = 0xd4d5aecb442c8e8c510ea16de16af34726babf069c375356b50468be21998242;
    /// (7, FIRST, DIFF, ROOT, 256 x "r", CAR)
    bytes32 constant LONG = 0x25028509d1c083e454d4dbc6840c45b88354603a44a96683298c26557bf6fd8a;
    /// (23, no parent, DIFF, ROOT, "a", CAR)
    bytes32 constant SMALL = 0xb3f8e42d45c2f0db59f96985b4528e253c855a01db88631ef84ed5182d584ef1;

    event Updated(
        address indexed publisher, bytes32 indexed repo_id, string repo, uint64 pos, bytes32 parent, bytes32 head
    );

    DataRegistry registry;
    address signer;
    uint256 signerKey;

    function setUp() public {
        vm.warp(uint256(E + 1) * 3600 + 5);
        registry = Proxied.dataRegistry(ADMIN);
        (signer, signerKey) = makeAddrAndKey("publisher");
    }

    function update(address who, string memory repo, uint64 epoch, bytes32 parent) internal returns (bytes32) {
        vm.prank(who);
        return registry.update(repo, epoch, parent, DIFF, ROOT, CAR);
    }

    function headOf(address who, string memory repo) internal view returns (uint64 pos, bytes32 head) {
        return registry.getHead(who, keccak256(bytes(repo)));
    }

    function digest(
        address publisher,
        string memory repo,
        uint64 epoch,
        bytes32 parent,
        bytes32 diff,
        bytes32 root,
        bytes memory car
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                registry.UPDATE_TYPEHASH(), publisher, keccak256(bytes(repo)), epoch, parent, diff, root, keccak256(car)
            )
        );
        return keccak256(abi.encodePacked(hex"1901", registry.domainSeparator(), structHash));
    }

    function sign(bytes32 d) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, d);
        return abi.encodePacked(r, s, v);
    }

    function test_initialization() public view {
        assertEq(registry.admin(), ADMIN);
        assertEq(registry.logLength(), 0);
    }

    // ── heads ─────────────────────────────────────────────────────────────────

    function test_commitHead_matches_the_sdk() public view {
        assertEq(registry.commitHead("photos", E, bytes32(0), DIFF, ROOT, CAR), FIRST);
        assertEq(registry.commitHead("photos", E + 1, FIRST, DIFF, ROOT, CAR), SECOND);
        bytes memory longName = new bytes(256);
        for (uint256 i = 0; i < 256; i++) {
            longName[i] = "r";
        }
        assertEq(registry.commitHead(string(longName), 7, FIRST, DIFF, ROOT, CAR), LONG);
        assertEq(registry.commitHead("a", 23, bytes32(0), DIFF, ROOT, CAR), SMALL);
    }

    function test_update_sets_the_computed_head() public {
        vm.expectEmit(true, true, true, true, address(registry));
        emit Updated(PUB, keccak256("photos"), "photos", 1, bytes32(0), FIRST);
        assertEq(update(PUB, "photos", E, bytes32(0)), FIRST);
        update(PUB, "photos", E + 1, FIRST);
        (uint64 pos, bytes32 head) = headOf(PUB, "photos");
        assertEq(pos, 2);
        assertEq(head, SECOND);
    }

    /// Golden fixture: a client derives the repo id the same way, to filter events and
    /// to address heads. If the derivations diverge, every read is zero.
    function test_repo_id_matches_fixture() public pure {
        assertEq(keccak256("docs"), 0x6bf9054545420e9e9f4aa4f353a32c7d0d52c11dbcdda56c53be8375cafeebb1);
    }

    function test_timelines_are_isolated_and_positions_count() public {
        update(PUB, "a", E, bytes32(0));
        update(signer, "a", E, bytes32(0));
        (uint64 pos, bytes32 head) = headOf(PUB, "b");
        assertEq(pos, 0);
        assertEq(head, bytes32(0));
        bytes32 b = update(PUB, "b", E, bytes32(0));
        bytes32 a1 = registry.commitHead("a", E, bytes32(0), DIFF, ROOT, CAR);
        update(PUB, "a", E, a1);
        (pos,) = headOf(PUB, "a");
        assertEq(pos, 2);
        (pos, head) = headOf(PUB, "b");
        assertEq(pos, 1);
        assertEq(head, b);
        (pos,) = headOf(signer, "a");
        assertEq(pos, 1);
    }

    function test_a_stale_parent_is_rejected() public {
        vm.prank(PUB);
        vm.expectRevert(DataRegistry.StaleStateRoot.selector);
        registry.update("photos", E, FIRST, DIFF, ROOT, CAR);
        update(PUB, "photos", E, bytes32(0));
        vm.prank(PUB);
        vm.expectRevert(DataRegistry.StaleStateRoot.selector);
        registry.update("photos", E, bytes32(0), DIFF, ROOT, CAR);
    }

    function test_epoch_window() public {
        uint64 now_ = registry.currentEpoch();
        uint64 w = registry.WINDOW();
        assertEq(now_, E + 1);

        vm.prank(PUB);
        vm.expectRevert(DataRegistry.EpochOutOfWindow.selector);
        registry.update("a", now_ + 1, bytes32(0), DIFF, ROOT, CAR);

        vm.prank(PUB);
        vm.expectRevert(DataRegistry.EpochOutOfWindow.selector);
        registry.update("a", now_ - w - 1, bytes32(0), DIFF, ROOT, CAR);

        update(PUB, "a", now_ - w, bytes32(0));
        update(PUB, "b", now_, bytes32(0));
    }

    function test_repo_ids_are_listed_once_in_first_write_order() public {
        update(PUB, "b", E, bytes32(0));
        update(PUB, "a", E, bytes32(0));
        update(PUB, "b", E, registry.commitHead("b", E, bytes32(0), DIFF, ROOT, CAR));
        assertEq(registry.repoCount(PUB), 2);
        assertEq(registry.repoIds(PUB, 0), keccak256("b"));
        assertEq(registry.repoIds(PUB, 1), keccak256("a"));
        assertEq(registry.repoCount(signer), 0);
    }

    // ── updateBySig ───────────────────────────────────────────────────────────

    function test_updateBySig_moves_the_signers_repo() public {
        bytes memory sig = sign(digest(signer, "photos", E, bytes32(0), DIFF, ROOT, CAR));
        vm.prank(PUB);
        registry.updateBySig(signer, "photos", E, bytes32(0), DIFF, ROOT, CAR, sig);
        (uint64 pos, bytes32 head) = headOf(signer, "photos");
        assertEq(pos, 1);
        assertEq(head, FIRST);
        (pos,) = headOf(PUB, "photos");
        assertEq(pos, 0);
    }

    function test_updateBySig_cannot_be_replayed() public {
        bytes memory sig = sign(digest(signer, "photos", E, bytes32(0), DIFF, ROOT, CAR));
        registry.updateBySig(signer, "photos", E, bytes32(0), DIFF, ROOT, CAR, sig);
        vm.expectRevert(DataRegistry.StaleStateRoot.selector);
        registry.updateBySig(signer, "photos", E, bytes32(0), DIFF, ROOT, CAR, sig);
    }

    function test_updateBySig_rejects_another_signer() public {
        (, uint256 other) = makeAddrAndKey("other");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(other, digest(signer, "photos", E, bytes32(0), DIFF, ROOT, CAR));
        vm.expectRevert(DataRegistry.BadSignature.selector);
        registry.updateBySig(signer, "photos", E, bytes32(0), DIFF, ROOT, CAR, abi.encodePacked(r, s, v));
    }

    function test_updateBySig_rejects_any_changed_field() public {
        bytes memory sig = sign(digest(signer, "photos", E, bytes32(0), DIFF, ROOT, CAR));
        vm.expectRevert(DataRegistry.BadSignature.selector);
        registry.updateBySig(signer, "videos", E, bytes32(0), DIFF, ROOT, CAR, sig);
        vm.expectRevert(DataRegistry.BadSignature.selector);
        registry.updateBySig(signer, "photos", E + 1, bytes32(0), DIFF, ROOT, CAR, sig);
        vm.expectRevert(DataRegistry.BadSignature.selector);
        registry.updateBySig(signer, "photos", E, bytes32(0), DIFF, bytes32(uint256(1)), CAR, sig);
        vm.expectRevert(DataRegistry.BadSignature.selector);
        registry.updateBySig(signer, "photos", E, bytes32(0), bytes32(uint256(2)), ROOT, CAR, sig);
        vm.expectRevert(DataRegistry.BadSignature.selector);
        registry.updateBySig(signer, "photos", E, bytes32(0), DIFF, ROOT, hex"0155", sig);
        vm.expectRevert(DataRegistry.BadSignature.selector);
        registry.updateBySig(PUB, "photos", E, bytes32(0), DIFF, ROOT, CAR, sig);
    }

    function test_updateBySig_is_bound_to_this_registry() public {
        DataRegistry other = Proxied.dataRegistry(ADMIN);
        bytes32 structHash = keccak256(
            abi.encode(
                registry.UPDATE_TYPEHASH(), signer, keccak256("photos"), E, bytes32(0), DIFF, ROOT, keccak256(CAR)
            )
        );
        bytes memory sig = sign(keccak256(abi.encodePacked(hex"1901", other.domainSeparator(), structHash)));
        vm.expectRevert(DataRegistry.BadSignature.selector);
        registry.updateBySig(signer, "photos", E, bytes32(0), DIFF, ROOT, CAR, sig);
    }

    function test_updateBySig_from_a_contract_wallet() public {
        DataWallet wallet = new DataWallet();
        wallet.approve(digest(address(wallet), "photos", E, bytes32(0), DIFF, ROOT, CAR));
        registry.updateBySig(address(wallet), "photos", E, bytes32(0), DIFF, ROOT, CAR, "");
        (uint64 pos,) = headOf(address(wallet), "photos");
        assertEq(pos, 1);
    }

    function test_updateBySig_checks_the_epoch_window() public {
        uint64 late = registry.currentEpoch() - registry.WINDOW() - 1;
        bytes memory sig = sign(digest(signer, "photos", late, bytes32(0), DIFF, ROOT, CAR));
        vm.expectRevert(DataRegistry.EpochOutOfWindow.selector);
        registry.updateBySig(signer, "photos", late, bytes32(0), DIFF, ROOT, CAR, sig);
    }

    // ── log ───────────────────────────────────────────────────────────────────

    /// Recomputes the mountain range from every leaf.
    function mmrRoot(bytes32[] memory leaves) internal pure returns (bytes32) {
        uint256 n = leaves.length;
        bytes32[] memory peaks = new bytes32[](64);
        uint256 count;
        uint256 offset;
        for (uint256 height = 64; height > 0; height--) {
            uint256 size = 1 << (height - 1);
            if (n & size == 0) continue;
            bytes32[] memory level = new bytes32[](size);
            for (uint256 i = 0; i < size; i++) {
                level[i] = leaves[offset + i];
            }
            for (uint256 w = size; w > 1; w /= 2) {
                for (uint256 i = 0; i < w / 2; i++) {
                    level[i] = keccak256(abi.encode(bytes32("node"), level[2 * i], level[2 * i + 1]));
                }
            }
            peaks[count++] = level[0];
            offset += size;
        }
        bytes32[] memory live = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            live[i] = peaks[i];
        }
        return keccak256(abi.encode(bytes32("mmr"), uint64(n), live));
    }

    function test_log_is_a_mountain_range_of_every_update() public {
        bytes32[] memory leaves = new bytes32[](11);
        bytes32 parent;
        for (uint256 i = 0; i < 11; i++) {
            vm.warp(block.timestamp + 1);
            bytes32 head = update(PUB, "photos", E, parent);
            leaves[i] = keccak256(
                abi.encode(bytes32("leaf"), PUB, keccak256("photos"), uint64(i + 1), head, uint64(block.timestamp))
            );
            parent = head;
            assertEq(registry.logLength(), i + 1);
            bytes32[] memory sofar = new bytes32[](i + 1);
            for (uint256 j = 0; j <= i; j++) {
                sofar[j] = leaves[j];
            }
            assertEq(registry.logRoot(), mmrRoot(sofar));
        }
    }

    function test_log_counts_only_valid_updates() public {
        update(PUB, "a", E, bytes32(0));
        vm.prank(PUB);
        vm.expectRevert(DataRegistry.StaleStateRoot.selector);
        registry.update("a", E, bytes32(0), DIFF, ROOT, CAR);
        assertEq(registry.logLength(), 1);
    }

    // ── upgrades ──────────────────────────────────────────────────────────────

    /// A new implementation takes over the same address and the same state — every
    /// head — and only the admin can install one.
    function test_an_upgrade_keeps_state_and_only_the_admin_can_do_it() public {
        bytes32 a = update(PUB, "a", E, bytes32(0));
        address v2 = address(new DataRegistryUpgradeMock());

        vm.prank(PUB);
        vm.expectRevert(DataRegistry.Unauthorized.selector);
        registry.upgradeToAndCall(v2, "");

        vm.prank(ADMIN);
        registry.upgradeToAndCall(v2, "");

        assertEq(DataRegistryUpgradeMock(address(registry)).version(), 2);
        assertEq(registry.admin(), ADMIN);
        (, bytes32 head) = headOf(PUB, "a");
        assertEq(head, a);

        // The timeline continues from where it was.
        update(PUB, "a", E, a);
        (uint64 pos,) = headOf(PUB, "a");
        assertEq(pos, 2);
    }

    /// `initialize` stands in for the constructor, so it runs exactly once — and never
    /// on the bare implementation, which nobody should be able to take over.
    function test_initialize_runs_once_and_never_on_the_implementation() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        registry.initialize(PUB);

        DataRegistry implementation = new DataRegistry();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(PUB);
    }

    /// The admin role moves, and the right to upgrade moves with it.
    function test_the_admin_role_can_be_handed_over() public {
        address v2 = address(new DataRegistryUpgradeMock());

        vm.prank(PUB);
        vm.expectRevert(DataRegistry.Unauthorized.selector);
        registry.setAdmin(PUB);

        vm.prank(ADMIN);
        registry.setAdmin(PUB);
        assertEq(registry.admin(), PUB);

        vm.prank(ADMIN);
        vm.expectRevert(DataRegistry.Unauthorized.selector);
        registry.upgradeToAndCall(v2, "");
        vm.prank(PUB);
        registry.upgradeToAndCall(v2, "");
    }
}
