// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AppRegistry} from "../src/AppRegistry.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {MockUSDC, Proxied} from "./Mocks.sol";

contract AppRegistryUpgradeMock is AppRegistry {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract AppRegistryTest is Test {
    address constant ADMIN = address(0x1111);
    address constant OWNER = address(0x2222);
    address constant CURATOR = address(0x3333);
    address constant STRANGER = address(0x4444);
    address constant PAYOUT = address(0x5555);

    bytes32 constant APP = bytes32(uint256(0xAA));
    bytes32 constant OTHER_APP = bytes32(uint256(0xBB));
    bytes32 constant GHOST_APP = bytes32(uint256(0xCC));
    bytes32 constant RENAMED = bytes32(uint256(0xDD));
    bytes32 constant RENAMED_AGAIN = bytes32(uint256(0xEE));

    AppRegistry apps;

    function setUp() public {
        apps = Proxied.appRegistry(ADMIN);
    }

    function openApp() internal {
        vm.prank(OWNER);
        apps.registerApp(APP);
    }

    // ── registering ───────────────────────────────────────────────────────────

    function test_an_app_id_is_registered_once_and_free() public {
        vm.expectEmit(true, true, true, true, address(apps));
        emit AppRegistry.AppRegistered(APP, OWNER);
        openApp();
        assertEq(apps.getAppOwner(APP), OWNER);

        vm.prank(STRANGER);
        vm.expectRevert(AppRegistry.AppAlreadyRegistered.selector);
        apps.registerApp(APP);

        vm.prank(STRANGER);
        vm.expectRevert(AppRegistry.ZeroAppId.selector);
        apps.registerApp(bytes32(0));
    }

    function test_apps_are_listed_in_order_and_by_owner() public {
        openApp();
        vm.prank(STRANGER);
        apps.registerApp(OTHER_APP);
        vm.prank(OWNER);
        apps.registerApp(GHOST_APP);

        assertEq(apps.appCount(), 3);
        bytes32[] memory page = apps.appsPage(1, 10);
        assertEq(page.length, 2);
        assertEq(page[0], OTHER_APP);
        assertEq(page[1], GHOST_APP);
        assertEq(apps.appsPage(3, 10).length, 0);
        assertEq(apps.appsPage(type(uint256).max, type(uint256).max).length, 0);
        assertEq(apps.appsOf(OWNER).length, 2);
        assertEq(apps.appsOf(OWNER)[1], GHOST_APP);
    }

    // ── curator, payout, agent card ───────────────────────────────────────────

    function test_curator_defaults_to_the_owner_with_no_repo() public {
        openApp();
        (address curator, string memory repo) = apps.curatorOf(APP);
        assertEq(curator, OWNER);
        assertEq(repo, "");
    }

    function test_the_owner_points_the_app_at_its_repo() public {
        openApp();
        vm.expectEmit(true, true, true, true, address(apps));
        emit AppRegistry.CuratorChanged(APP, CURATOR, "picks");
        vm.prank(OWNER);
        apps.setCurator(APP, CURATOR, "picks");
        (address curator, string memory repo) = apps.curatorOf(APP);
        assertEq(curator, CURATOR);
        assertEq(repo, "picks");

        vm.prank(OWNER);
        apps.setCurator(APP, address(0), "mine");
        (curator, repo) = apps.curatorOf(APP);
        assertEq(curator, OWNER);
        assertEq(repo, "mine");
    }

    function test_payout_defaults_to_the_owner_and_the_owner_sets_it() public {
        openApp();
        assertEq(apps.payoutOf(APP), OWNER);
        vm.expectEmit(true, true, true, true, address(apps));
        emit AppRegistry.PayoutChanged(APP, PAYOUT);
        vm.prank(OWNER);
        apps.setPayout(APP, PAYOUT);
        assertEq(apps.payoutOf(APP), PAYOUT);
        vm.prank(OWNER);
        apps.setPayout(APP, address(0));
        assertEq(apps.payoutOf(APP), OWNER);
    }

    function test_unregistered_apps_have_no_curator_or_payout() public view {
        (address curator,) = apps.curatorOf(GHOST_APP);
        assertEq(curator, address(0));
        assertEq(apps.payoutOf(GHOST_APP), address(0));
    }

    function test_only_the_owner_changes_an_app() public {
        openApp();
        address[2] memory others = [STRANGER, ADMIN];
        for (uint256 i = 0; i < others.length; i++) {
            vm.startPrank(others[i]);
            vm.expectRevert(AppRegistry.Unauthorized.selector);
            apps.setCurator(APP, CURATOR, "x");
            vm.expectRevert(AppRegistry.Unauthorized.selector);
            apps.setPayout(APP, PAYOUT);
            vm.expectRevert(AppRegistry.Unauthorized.selector);
            apps.setAppAgentUri(APP, "ipfs://x");
            vm.expectRevert(AppRegistry.Unauthorized.selector);
            apps.renameApp(APP, RENAMED);
            vm.stopPrank();
        }
        vm.startPrank(OWNER);
        vm.expectRevert(AppRegistry.AppNotFound.selector);
        apps.setCurator(GHOST_APP, CURATOR, "x");
        vm.expectRevert(AppRegistry.AppNotFound.selector);
        apps.setPayout(GHOST_APP, PAYOUT);
        vm.expectRevert(AppRegistry.AppNotFound.selector);
        apps.setAppAgentUri(GHOST_APP, "ipfs://x");
        vm.stopPrank();
    }

    function test_the_owner_sets_the_agent_card() public {
        openApp();
        vm.expectEmit(true, true, true, true, address(apps));
        emit AppRegistry.AppAgentChanged(APP, "ipfs://card");
        vm.prank(OWNER);
        apps.setAppAgentUri(APP, "ipfs://card");
        assertEq(apps.appAgentUri(APP), "ipfs://card");
    }

    // ── renaming ──────────────────────────────────────────────────────────────

    function test_a_renamed_app_answers_to_every_id_it_went_by() public {
        openApp();
        vm.expectEmit(true, true, true, true, address(apps));
        emit AppRegistry.AppRenamed(APP, RENAMED);
        vm.prank(OWNER);
        apps.renameApp(APP, RENAMED);

        assertEq(apps.currentAppId(APP), RENAMED);
        assertEq(apps.currentAppId(RENAMED), RENAMED);
        assertEq(apps.canonicalAppId(RENAMED), APP);
        assertEq(apps.canonicalAppId(GHOST_APP), GHOST_APP);
        assertEq(apps.currentAppId(GHOST_APP), GHOST_APP);

        // Managed under its new id; events keep the canonical one.
        vm.startPrank(OWNER);
        vm.expectEmit(true, true, true, true, address(apps));
        emit AppRegistry.CuratorChanged(APP, CURATOR, "picks");
        apps.setCurator(RENAMED, CURATOR, "picks");
        apps.setPayout(RENAMED, PAYOUT);
        apps.setAppAgentUri(RENAMED, "ipfs://card");
        vm.stopPrank();
        vm.prank(ADMIN);
        apps.setAppSuspended(RENAMED, true);

        bytes32[2] memory ids = [APP, RENAMED];
        for (uint256 i = 0; i < ids.length; i++) {
            assertEq(apps.getAppOwner(ids[i]), OWNER);
            (address curator, string memory repo) = apps.curatorOf(ids[i]);
            assertEq(curator, CURATOR);
            assertEq(repo, "picks");
            assertEq(apps.payoutOf(ids[i]), PAYOUT);
            assertEq(apps.appAgentUri(ids[i]), "ipfs://card");
            assertTrue(apps.isAppSuspended(ids[i]));
        }
        assertEq(apps.appCount(), 1);
        assertEq(apps.appsPage(0, 10)[0], APP);
    }

    function test_an_app_keeps_every_id_it_went_by() public {
        openApp();
        vm.startPrank(OWNER);
        apps.renameApp(APP, RENAMED);
        apps.renameApp(RENAMED, RENAMED_AGAIN);
        vm.stopPrank();
        assertEq(apps.currentAppId(APP), RENAMED_AGAIN);
        assertEq(apps.canonicalAppId(RENAMED_AGAIN), APP);

        vm.startPrank(STRANGER);
        vm.expectRevert(AppRegistry.AppAlreadyRegistered.selector);
        apps.registerApp(RENAMED);
        apps.registerApp(OTHER_APP);
        vm.expectRevert(AppRegistry.AppAlreadyRegistered.selector);
        apps.renameApp(OTHER_APP, RENAMED);
        vm.expectRevert(AppRegistry.AppAlreadyRegistered.selector);
        apps.renameApp(OTHER_APP, APP);
        vm.stopPrank();

        vm.startPrank(OWNER);
        apps.renameApp(RENAMED_AGAIN, RENAMED);
        assertEq(apps.currentAppId(APP), RENAMED);
        apps.renameApp(RENAMED, APP);
        assertEq(apps.currentAppId(RENAMED), APP);
        vm.expectRevert(AppRegistry.ZeroAppId.selector);
        apps.renameApp(APP, bytes32(0));
        vm.stopPrank();
    }

    // ── admin ─────────────────────────────────────────────────────────────────

    function test_only_the_admin_suspends_an_app() public {
        openApp();
        vm.prank(OWNER);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.setAppSuspended(APP, true);

        vm.expectEmit(true, true, true, true, address(apps));
        emit AppRegistry.AppSuspensionChanged(APP, true);
        vm.prank(ADMIN);
        apps.setAppSuspended(APP, true);
        assertTrue(apps.isAppSuspended(APP));
        vm.prank(ADMIN);
        apps.setAppSuspended(APP, false);
        assertFalse(apps.isAppSuspended(APP));

        vm.prank(ADMIN);
        vm.expectRevert(AppRegistry.AppNotFound.selector);
        apps.setAppSuspended(GHOST_APP, true);
    }

    function test_only_the_admin_sets_the_data_registry() public {
        vm.prank(STRANGER);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.setDataRegistry(address(0xDA7A));
        vm.expectEmit(true, true, true, true, address(apps));
        emit AppRegistry.DataRegistryChanged(address(0), address(0xDA7A));
        vm.prank(ADMIN);
        apps.setDataRegistry(address(0xDA7A));
        assertEq(apps.dataRegistry(), address(0xDA7A));
    }

    function test_only_the_admin_withdraws_tokens() public {
        MockUSDC usdc = new MockUSDC();
        vm.prank(STRANGER);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.withdrawToken(address(usdc), STRANGER, 5);

        vm.prank(ADMIN);
        apps.withdrawToken(address(usdc), PAYOUT, 5);
        assertEq(usdc.balanceOf(PAYOUT), 5);

        usdc.setMode(MockUSDC.Mode.ReturnFalse);
        vm.prank(ADMIN);
        vm.expectRevert(AppRegistry.TransferFailed.selector);
        apps.withdrawToken(address(usdc), PAYOUT, 1);
    }

    // ── upgrades ──────────────────────────────────────────────────────────────

    function test_an_upgrade_keeps_state_and_only_the_admin_can_do_it() public {
        openApp();
        vm.prank(OWNER);
        apps.setCurator(APP, CURATOR, "picks");
        address v2 = address(new AppRegistryUpgradeMock());

        vm.prank(OWNER);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.upgradeToAndCall(v2, "");

        vm.prank(ADMIN);
        apps.upgradeToAndCall(v2, "");

        assertEq(AppRegistryUpgradeMock(address(apps)).version(), 2);
        assertEq(apps.admin(), ADMIN);
        assertEq(apps.getAppOwner(APP), OWNER);
        (address curator,) = apps.curatorOf(APP);
        assertEq(curator, CURATOR);
    }

    function test_initialize_runs_once_and_never_on_the_implementation() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        apps.initialize(STRANGER);

        AppRegistry implementation = new AppRegistry();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(STRANGER);
    }

    function test_the_admin_role_can_be_handed_over() public {
        address v2 = address(new AppRegistryUpgradeMock());
        vm.prank(STRANGER);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.setAdmin(STRANGER);

        vm.prank(ADMIN);
        apps.setAdmin(STRANGER);
        assertEq(apps.admin(), STRANGER);

        vm.prank(ADMIN);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.upgradeToAndCall(v2, "");
        vm.prank(STRANGER);
        apps.upgradeToAndCall(v2, "");
    }
}
