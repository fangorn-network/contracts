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

/// The DataRegistry on its own: it calls nothing.
contract DataRegistryTest is Test {
    address constant ADMIN = 0x1111111111111111111111111111111111111111;
    address constant PUB = 0x2222222222222222222222222222222222222222;
    address constant APPS = 0x3333333333333333333333333333333333333333;
    bytes32 constant ROOT_A = bytes32(uint256(5));
    bytes32 constant ROOT_B = bytes32(uint256(6));

    event Updated(
        address indexed publisher, bytes32 indexed repo_id, string repo, uint64 pos, bytes32 parent, bytes32 head
    );

    DataRegistry registry;

    function setUp() public {
        registry = Proxied.dataRegistry(ADMIN, APPS);
    }

    function update(address who, string memory repo, bytes32 parent, bytes32 head) internal {
        vm.prank(who);
        registry.update(repo, parent, head);
    }

    function headOf(address who, string memory repo) internal view returns (uint64 pos, bytes32 head) {
        return registry.getHead(who, keccak256(bytes(repo)));
    }

    function test_initialization() public view {
        assertEq(registry.admin(), ADMIN);
        assertEq(registry.appRegistry(), APPS);
    }

    /// Any address updates its own repos, with no app and no registration.
    function test_anyone_updates_their_own_repos() public {
        update(PUB, "a", bytes32(0), ROOT_A);
        update(ADMIN, "a", bytes32(0), ROOT_B);
        (uint64 pos, bytes32 head) = headOf(PUB, "a");
        assertEq(pos, 1);
        assertEq(head, ROOT_A);
        (, head) = headOf(ADMIN, "a");
        assertEq(head, ROOT_B);
    }

    /// Golden fixture: a client derives the repo id the same way, to filter events and
    /// to address heads. If the derivations diverge, every read is zero.
    function test_repo_id_matches_fixture() public {
        bytes32 repoId = keccak256("docs");
        assertEq(repoId, 0x6bf9054545420e9e9f4aa4f353a32c7d0d52c11dbcdda56c53be8375cafeebb1);

        vm.expectEmit(true, true, true, true, address(registry));
        emit Updated(PUB, repoId, "docs", 1, bytes32(0), ROOT_A);
        update(PUB, "docs", bytes32(0), ROOT_A);
    }

    /// Each publisher and each repo has its own timeline, and positions count its heads.
    function test_timelines_are_isolated_and_positions_count() public {
        update(PUB, "a", bytes32(0), ROOT_A);
        (uint64 pos, bytes32 head) = headOf(PUB, "b");
        assertEq(pos, 0);
        assertEq(head, bytes32(0));
        update(PUB, "b", bytes32(0), ROOT_B);
        update(PUB, "a", ROOT_A, ROOT_B);
        (pos, head) = headOf(PUB, "a");
        assertEq(pos, 2);
        assertEq(head, ROOT_B);
        (pos,) = headOf(PUB, "b");
        assertEq(pos, 1);
    }

    function test_a_stale_parent_or_a_zero_head_is_rejected() public {
        vm.prank(PUB);
        vm.expectRevert(DataRegistry.StaleStateRoot.selector);
        registry.update("a", ROOT_A, ROOT_B);

        vm.prank(PUB);
        vm.expectRevert(DataRegistry.ZeroHead.selector);
        registry.update("a", bytes32(0), bytes32(0));
    }

    /// Only the admin repoints the AppRegistry it names.
    function test_only_the_admin_repoints_the_app_registry() public {
        vm.prank(PUB);
        vm.expectRevert(DataRegistry.Unauthorized.selector);
        registry.setAppRegistry(PUB);

        vm.prank(ADMIN);
        registry.setAppRegistry(PUB);
        assertEq(registry.appRegistry(), PUB);
    }

    // ── upgrades ──────────────────────────────────────────────────────────────

    /// A new implementation takes over the same address and the same state — every
    /// head — and only the admin can install one.
    function test_an_upgrade_keeps_state_and_only_the_admin_can_do_it() public {
        update(PUB, "a", bytes32(0), ROOT_A);
        address v2 = address(new DataRegistryUpgradeMock());

        vm.prank(PUB);
        vm.expectRevert(DataRegistry.Unauthorized.selector);
        registry.upgradeToAndCall(v2, "");

        vm.prank(ADMIN);
        registry.upgradeToAndCall(v2, "");

        assertEq(DataRegistryUpgradeMock(address(registry)).version(), 2);
        assertEq(registry.admin(), ADMIN);
        assertEq(registry.appRegistry(), APPS);
        (, bytes32 head) = headOf(PUB, "a");
        assertEq(head, ROOT_A);

        // The timeline continues from where it was.
        update(PUB, "a", ROOT_A, ROOT_B);
        (, head) = headOf(PUB, "a");
        assertEq(head, ROOT_B);
    }

    /// `initialize` stands in for the constructor, so it runs exactly once — and never
    /// on the bare implementation, which nobody should be able to take over.
    function test_initialize_runs_once_and_never_on_the_implementation() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        registry.initialize(PUB, APPS);

        DataRegistry implementation = new DataRegistry();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(PUB, APPS);
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
