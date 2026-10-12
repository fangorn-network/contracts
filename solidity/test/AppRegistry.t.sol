// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AppRegistry} from "../src/AppRegistry.sol";
import {DataRegistry} from "../src/DataRegistry.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {MockUSDC, Reverter, Proxied} from "./Mocks.sol";

/// An app owner that cannot receive ETH, so a join fee paid to it is undeliverable.
contract PennilessOwner {
    function claim(DataRegistry data, AppRegistry apps, bytes32 app, bytes32 terms, uint256 fee, address invitee)
        external
    {
        data.register();
        apps.registerApp(app, terms, "", fee);
        apps.addPublisher(app, invitee);
    }
}

/// What an upgrade installs: the same contract, plus one function to tell it by.
contract AppRegistryUpgradeMock is AppRegistry {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// The cases from `stylus/app_registry`'s tests, against the real DataRegistry
/// rather than a mock of it. Foundry also lets these assert what TestVM could not:
/// that ETH actually moves, that a revert unwinds state, and that an unwired
/// DataRegistry fails closed.
contract AppRegistryTest is Test {
    address constant ADMIN = 0x1111111111111111111111111111111111111111;
    address constant APP_OWNER = 0x2222222222222222222222222222222222222222;
    address constant PUBLISHER = 0x3333333333333333333333333333333333333333;
    address constant STRANGER = 0x4444444444444444444444444444444444444444;
    /// A wallet the DataRegistry does not know.
    address constant OUTSIDER = 0x8888888888888888888888888888888888888888;

    bytes32 constant APP = bytes32(uint256(0xAA));
    bytes32 constant OTHER_APP = bytes32(uint256(0xBB));
    bytes32 constant GHOST_APP = bytes32(uint256(0xCC));
    bytes32 constant TERMS_V1 = bytes32(uint256(0x11));
    bytes32 constant TERMS_V2 = bytes32(uint256(0x22));
    uint256 constant FEE = 0.001 ether;
    uint256 constant SUB_FEE = 2_000_000; // 2 USDC (6 decimals)

    uint8 constant STATUS_UNREGISTERED = 0;
    uint8 constant STATUS_ACTIVE = 1;
    uint8 constant STATUS_INVITED = 3;

    AppRegistry apps;
    DataRegistry data;
    MockUSDC usdc;

    /// Both registries, wired to each other. The subscription fee starts at zero.
    /// Three everyday wallets are registered publishers; OUTSIDER is not.
    function setUp() public {
        usdc = new MockUSDC();
        data = Proxied.dataRegistry(ADMIN, 0, address(0));
        apps = Proxied.appRegistry(ADMIN, address(usdc), 0, address(data));
        vm.prank(ADMIN);
        data.setAppRegistry(address(apps));

        address[3] memory everyday = [APP_OWNER, PUBLISHER, STRANGER];
        for (uint256 i = 0; i < everyday.length; i++) {
            vm.prank(everyday[i]);
            data.register();
            vm.deal(everyday[i], 10 ether);
        }
    }

    /// APP claimed by APP_OWNER, with terms and a join fee, and PUBLISHER invited —
    /// ready for PUBLISHER to join.
    function openApp() internal {
        vm.startPrank(APP_OWNER);
        apps.registerApp(APP, TERMS_V1, "https://tabs.example/terms", FEE);
        apps.addPublisher(APP, PUBLISHER);
        vm.stopPrank();
    }

    function join(address who, bytes32 app, bytes32 terms, uint256 value) internal {
        vm.prank(who);
        apps.registerForApp{value: value}(app, terms);
    }

    // ── apps ──────────────────────────────────────────────────────────────────

    function test_only_the_app_owner_sets_terms_and_fee() public {
        openApp();
        assertEq(apps.getAppOwner(APP), APP_OWNER);

        vm.startPrank(STRANGER);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.setAppTerms(APP, TERMS_V2, "");
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.setAppFee(APP, FEE);
        vm.expectRevert(AppRegistry.AppAlreadyRegistered.selector);
        apps.registerApp(APP, TERMS_V2, "", 0);
        vm.stopPrank();

        // Not even the protocol admin — the app owner's obligations are their own.
        vm.prank(ADMIN);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.setAppTerms(APP, TERMS_V2, "");

        vm.prank(APP_OWNER);
        apps.setAppTerms(APP, TERMS_V2, "https://tabs.example/v2");
        assertEq(apps.appTerms(APP), TERMS_V2);
        assertEq(apps.appTermsUri(APP), "https://tabs.example/v2");
    }

    function test_an_unclaimed_app_cannot_be_configured_or_joined() public {
        vm.prank(APP_OWNER);
        vm.expectRevert(AppRegistry.AppNotFound.selector);
        apps.setAppTerms(GHOST_APP, TERMS_V1, "");

        vm.prank(APP_OWNER);
        vm.expectRevert(AppRegistry.AppNotFound.selector);
        apps.addPublisher(GHOST_APP, PUBLISHER);

        vm.prank(PUBLISHER);
        vm.expectRevert(AppRegistry.AppNotFound.selector);
        apps.registerForApp(GHOST_APP, TERMS_V1);
    }

    function test_an_app_owner_is_their_own_first_publisher() public {
        openApp();
        assertTrue(apps.isRegisteredForApp(APP, APP_OWNER));

        // ...and editing the terms must not lock them out of their own app either.
        vm.prank(APP_OWNER);
        apps.setAppTerms(APP, TERMS_V2, "");
        assertTrue(apps.isRegisteredForApp(APP, APP_OWNER));
        assertEq(apps.acceptedTerms(APP, APP_OWNER), TERMS_V2);

        // Claiming an app must not enrol you anywhere else.
        assertFalse(apps.isRegisteredForApp(OTHER_APP, APP_OWNER));
    }

    function test_moving_the_agent_card_leaves_registrations_alone() public {
        openApp();
        join(PUBLISHER, APP, TERMS_V1, FEE);

        vm.prank(STRANGER);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.setAppAgentUri(APP, "https://evil.example/card.json");

        vm.startPrank(APP_OWNER);
        apps.setAppAgentUri(APP, "https://a.example/card.json");
        apps.setAppAgentUri(APP, "https://b.example/card.json");
        vm.stopPrank();
        assertEq(apps.appAgentUri(APP), "https://b.example/card.json");

        // The exact trap this field exists to avoid: the card moved, nobody was
        // unregistered.
        assertEq(apps.appTerms(APP), TERMS_V1);
        assertEq(apps.acceptedTerms(APP, PUBLISHER), TERMS_V1);
        assertTrue(apps.isRegisteredForApp(APP, PUBLISHER));
        assertEq(apps.appAgentUri(OTHER_APP), "");
    }

    function test_the_admin_can_take_down_a_whole_app() public {
        openApp();
        vm.prank(APP_OWNER);
        apps.registerApp(OTHER_APP, TERMS_V1, "", 0);
        join(PUBLISHER, APP, TERMS_V1, FEE);

        // The app owner has no say over their own takedown, and a stranger even less.
        vm.prank(APP_OWNER);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.suspendApp(APP);
        vm.prank(STRANGER);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.suspendApp(APP);

        vm.startPrank(ADMIN);
        vm.expectRevert(AppRegistry.AppNotFound.selector);
        apps.suspendApp(GHOST_APP);
        apps.suspendApp(APP);
        vm.stopPrank();
        assertTrue(apps.isAppSuspended(APP));

        // Everyone is out, owner included, and nothing about the other app moved.
        assertFalse(apps.isRegisteredForApp(APP, PUBLISHER));
        assertFalse(apps.isRegisteredForApp(APP, APP_OWNER));
        assertTrue(apps.isRegisteredForApp(OTHER_APP, APP_OWNER));

        // No joining a suspended app, and per-publisher status is untouched underneath.
        vm.prank(APP_OWNER);
        apps.addPublisher(APP, STRANGER);
        vm.prank(STRANGER);
        vm.expectRevert(AppRegistry.AppSuspendedErr.selector);
        apps.registerForApp{value: FEE}(APP, TERMS_V1);
        assertEq(apps.statusForApp(APP, PUBLISHER), STATUS_ACTIVE);

        // Reinstating restores the memberships exactly as they were.
        vm.prank(ADMIN);
        apps.reinstateApp(APP);
        assertTrue(apps.isRegisteredForApp(APP, PUBLISHER));
        assertTrue(apps.isRegisteredForApp(APP, APP_OWNER));
    }

    // ── joining ───────────────────────────────────────────────────────────────

    function test_only_an_invited_publisher_can_join() public {
        openApp();

        // An invitation is not a membership.
        assertEq(apps.statusForApp(APP, PUBLISHER), STATUS_INVITED);
        assertFalse(apps.isRegisteredForApp(APP, PUBLISHER));

        vm.startPrank(STRANGER);
        vm.expectRevert(AppRegistry.NotInvited.selector);
        apps.registerForApp{value: FEE}(APP, TERMS_V1);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.addPublisher(APP, STRANGER);
        vm.stopPrank();

        vm.startPrank(APP_OWNER);
        vm.expectRevert(AppRegistry.AlreadyRegistered.selector);
        apps.addPublisher(APP, PUBLISHER);

        // The owner can take an invitation back before it is used.
        apps.addPublisher(APP, STRANGER);
        apps.suspendForApp(APP, STRANGER);
        vm.stopPrank();
        vm.prank(STRANGER);
        vm.expectRevert(AppRegistry.PublisherSuspendedErr.selector);
        apps.registerForApp{value: FEE}(APP, TERMS_V1);
    }

    function test_registering_agrees_to_an_exact_terms_version() public {
        // An app claimed with no terms: nothing to agree to, so joining is refused
        // rather than recording consent to a zero hash.
        vm.startPrank(APP_OWNER);
        apps.registerApp(OTHER_APP, bytes32(0), "", 0);
        apps.addPublisher(OTHER_APP, PUBLISHER);
        vm.stopPrank();
        vm.prank(PUBLISHER);
        vm.expectRevert(AppRegistry.TermsNotSet.selector);
        apps.registerForApp(OTHER_APP, bytes32(0));

        openApp();

        // The wrong version reverts: an owner must not be able to swap the terms
        // under a pending registration and have it land as consent to the new ones.
        vm.prank(PUBLISHER);
        vm.expectRevert(AppRegistry.TermsMismatch.selector);
        apps.registerForApp{value: FEE}(APP, TERMS_V2);

        join(PUBLISHER, APP, TERMS_V1, FEE);
        assertTrue(apps.isRegisteredForApp(APP, PUBLISHER));
        assertEq(apps.acceptedTerms(APP, PUBLISHER), TERMS_V1);

        // Idempotence: no paying twice for the same membership.
        vm.prank(PUBLISHER);
        vm.expectRevert(AppRegistry.AlreadyRegistered.selector);
        apps.registerForApp{value: FEE}(APP, TERMS_V1);
    }

    function test_the_fee_is_required_and_goes_to_the_app_owner() public {
        openApp();

        vm.prank(PUBLISHER);
        vm.expectRevert(AppRegistry.JoinFeeRequired.selector);
        apps.registerForApp{value: FEE - 1}(APP, TERMS_V1);

        uint256 ownerBefore = APP_OWNER.balance;
        join(PUBLISHER, APP, TERMS_V1, FEE);
        assertTrue(apps.isRegisteredForApp(APP, PUBLISHER));
        assertEq(APP_OWNER.balance, ownerBefore + FEE, "the join fee did not reach the app owner");
        assertEq(address(apps).balance, 0, "the registry kept the join fee");
    }

    function test_an_undeliverable_join_fee_aborts_the_registration() public {
        PennilessOwner owner = new PennilessOwner();
        owner.claim(data, apps, OTHER_APP, TERMS_V1, FEE, PUBLISHER);

        vm.prank(PUBLISHER);
        vm.expectRevert(AppRegistry.TransferFailed.selector);
        apps.registerForApp{value: FEE}(OTHER_APP, TERMS_V1);

        // The payout failure unwound the membership: nobody was admitted for free.
        assertEq(apps.statusForApp(OTHER_APP, PUBLISHER), STATUS_INVITED);
        assertFalse(apps.isRegisteredForApp(OTHER_APP, PUBLISHER));
    }

    function test_moving_the_terms_drops_everyone_back_to_unaccepted() public {
        openApp();
        join(PUBLISHER, APP, TERMS_V1, FEE);

        vm.prank(APP_OWNER);
        apps.setAppTerms(APP, TERMS_V2, "https://tabs.example/terms-v2");

        // Not registered any more — but distinguishably so: still ACTIVE, on a stale
        // hash. A UI that only had the boolean would say "you were never here".
        assertFalse(apps.isRegisteredForApp(APP, PUBLISHER));
        assertEq(apps.statusForApp(APP, PUBLISHER), STATUS_ACTIVE);
        assertEq(apps.acceptedTerms(APP, PUBLISHER), TERMS_V1);

        // Re-accepting is free. An app must not be able to bill its whole publisher
        // base by editing a sentence.
        join(PUBLISHER, APP, TERMS_V2, 0);
        assertTrue(apps.isRegisteredForApp(APP, PUBLISHER));
    }

    function test_membership_is_per_app() public {
        openApp();
        vm.prank(APP_OWNER);
        apps.registerApp(OTHER_APP, TERMS_V2, "", 0);
        join(PUBLISHER, APP, TERMS_V1, FEE);

        assertTrue(apps.isRegisteredForApp(APP, PUBLISHER));
        assertFalse(apps.isRegisteredForApp(OTHER_APP, PUBLISHER));
        assertFalse(apps.isRegisteredForApp(APP, STRANGER));
    }

    function test_an_app_owner_can_eject_a_publisher_from_their_app_only() public {
        openApp();
        vm.startPrank(APP_OWNER);
        apps.registerApp(OTHER_APP, TERMS_V1, "", 0);
        apps.addPublisher(OTHER_APP, PUBLISHER);
        vm.stopPrank();
        join(PUBLISHER, APP, TERMS_V1, FEE);
        join(PUBLISHER, OTHER_APP, TERMS_V1, 0);

        vm.prank(STRANGER);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.suspendForApp(APP, PUBLISHER);

        vm.prank(APP_OWNER);
        apps.suspendForApp(APP, PUBLISHER);
        assertFalse(apps.isRegisteredForApp(APP, PUBLISHER));
        assertTrue(apps.isRegisteredForApp(OTHER_APP, PUBLISHER), "one app's ban leaked into another");

        // Paying again is not a way back in.
        vm.prank(PUBLISHER);
        vm.expectRevert(AppRegistry.PublisherSuspendedErr.selector);
        apps.registerForApp{value: FEE}(APP, TERMS_V1);

        vm.startPrank(APP_OWNER);
        vm.expectRevert(AppRegistry.NotRegistered.selector);
        apps.reinstateForApp(APP, STRANGER);
        apps.reinstateForApp(APP, PUBLISHER);
        vm.stopPrank();
        assertTrue(apps.isRegisteredForApp(APP, PUBLISHER));
    }

    function test_join_info_answers_a_join_screen_in_one_call() public {
        openApp();
        (bytes32 hash, string memory uri, uint256 fee, uint8 status, bool registered) = apps.joinInfo(APP, PUBLISHER);
        assertEq(hash, TERMS_V1);
        assertEq(uri, "https://tabs.example/terms");
        assertEq(fee, FEE);
        assertEq(status, STATUS_INVITED);
        assertFalse(registered);

        (,,, uint8 strangerStatus,) = apps.joinInfo(APP, STRANGER);
        assertEq(strangerStatus, STATUS_UNREGISTERED);
    }

    // ── subscription ──────────────────────────────────────────────────────────

    function test_claiming_an_app_pays_its_subscription() public {
        vm.prank(STRANGER);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.setSubscriptionFee(1);
        vm.prank(ADMIN);
        apps.setSubscriptionFee(SUB_FEE);
        assertEq(apps.subscriptionFee(), SUB_FEE);
        assertEq(apps.usdc(), address(usdc));

        // No payment, no app — whether the token reverts or just answers `false`.
        MockUSDC.Mode[2] memory refusals = [MockUSDC.Mode.Revert, MockUSDC.Mode.ReturnFalse];
        for (uint256 i = 0; i < refusals.length; i++) {
            usdc.setMode(refusals[i]);
            vm.prank(STRANGER);
            vm.expectRevert(AppRegistry.SubscriptionFeeRequired.selector);
            apps.registerApp(OTHER_APP, TERMS_V1, "", 0);
            assertEq(apps.getAppOwner(OTHER_APP), address(0), "an unpaid claim left an app behind");
            assertEq(apps.subscribedAt(OTHER_APP), 0);
        }
        usdc.setMode(MockUSDC.Mode.Ok);

        vm.warp(1_700_000_000);
        vm.prank(APP_OWNER);
        apps.registerApp(APP, TERMS_V1, "", 0);
        assertEq(apps.subscribedAt(APP), 1_700_000_000);
        // The fee was pulled from the claimer into the registry.
        assertEq(usdc.lastFrom(), APP_OWNER);
        assertEq(usdc.lastTo(), address(apps));
        assertEq(usdc.lastAmount(), SUB_FEE);

        // The gate's one read: membership, who owns the app, and when it last paid.
        (bool registered, address owner, uint64 paidAt) = apps.access(APP, APP_OWNER);
        assertTrue(registered);
        assertEq(owner, APP_OWNER);
        assertEq(paidAt, 1_700_000_000);
        (registered, owner, paidAt) = apps.access(APP, STRANGER);
        assertFalse(registered);
        assertEq(owner, APP_OWNER);
        (registered, owner, paidAt) = apps.access(OTHER_APP, STRANGER);
        assertFalse(registered);
        assertEq(owner, address(0));
        assertEq(paidAt, 0);

        // Renewing is the owner's to do, and re-stamps to the new now.
        vm.warp(1_700_100_000);
        vm.prank(STRANGER);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.renewApp(APP);
        vm.prank(APP_OWNER);
        apps.renewApp(APP);
        assertEq(apps.subscribedAt(APP), 1_700_100_000);
        assertEq(usdc.calls(), 2);
    }

    function test_a_free_subscription_never_touches_the_token() public {
        // Fee is zero and the token would revert: the claim must not call it.
        usdc.setMode(MockUSDC.Mode.Revert);
        vm.prank(APP_OWNER);
        apps.registerApp(APP, TERMS_V1, "", 0);
        assertEq(apps.getAppOwner(APP), APP_OWNER);
        assertEq(usdc.calls(), 0);
    }

    function test_only_the_admin_sweeps_the_subscription_fees() public {
        vm.prank(APP_OWNER);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.withdrawUsdc(STRANGER, SUB_FEE);

        vm.prank(ADMIN);
        apps.withdrawUsdc(STRANGER, SUB_FEE);
        assertEq(usdc.lastTo(), STRANGER);
        assertEq(usdc.lastAmount(), SUB_FEE);

        usdc.setMode(MockUSDC.Mode.ReturnFalse);
        vm.prank(ADMIN);
        vm.expectRevert(AppRegistry.TransferFailed.selector);
        apps.withdrawUsdc(STRANGER, SUB_FEE);
    }

    // ── the DataRegistry's say ────────────────────────────────────────────────

    function test_claiming_and_adding_need_data_registry_registration() public {
        assertEq(apps.dataRegistry(), address(data));

        // Never registered: no app for them.
        vm.prank(OUTSIDER);
        vm.expectRevert(AppRegistry.NotRegisteredGlobally.selector);
        apps.registerApp(APP, TERMS_V1, "", 0);
        assertEq(apps.getAppOwner(APP), address(0));

        // ...and an owner cannot bring one in either.
        vm.startPrank(APP_OWNER);
        apps.registerApp(APP, TERMS_V1, "", 0);
        vm.expectRevert(AppRegistry.NotRegisteredGlobally.selector);
        apps.addPublisher(APP, OUTSIDER);
        vm.stopPrank();
        assertEq(apps.statusForApp(APP, OUTSIDER), STATUS_UNREGISTERED);

        // Once they register, both work.
        vm.prank(OUTSIDER);
        data.register();
        vm.prank(APP_OWNER);
        apps.addPublisher(APP, OUTSIDER);
        assertEq(apps.statusForApp(APP, OUTSIDER), STATUS_INVITED);
    }

    /// The reason the check exists: a wallet the protocol admin banned network-wide
    /// cannot come back as an app owner, or be brought into an app by one.
    function test_a_globally_banned_wallet_can_neither_claim_nor_be_added() public {
        vm.prank(ADMIN);
        data.suspendPublisher(STRANGER);

        vm.prank(STRANGER);
        vm.expectRevert(AppRegistry.NotRegisteredGlobally.selector);
        apps.registerApp(OTHER_APP, TERMS_V1, "", 0);

        openApp();
        vm.prank(APP_OWNER);
        vm.expectRevert(AppRegistry.NotRegisteredGlobally.selector);
        apps.addPublisher(APP, STRANGER);

        vm.prank(ADMIN);
        data.reinstateGlobal(STRANGER);
        vm.prank(APP_OWNER);
        apps.addPublisher(APP, STRANGER);
    }

    /// With no usable DataRegistry, nobody reads as registered: unset, an address
    /// with no code, and a registry that reverts all refuse the claim.
    function test_an_unwired_data_registry_fails_closed() public {
        vm.prank(STRANGER);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.setDataRegistry(STRANGER);

        address[3] memory broken = [address(0), makeAddr("no-code"), address(new Reverter())];
        for (uint256 i = 0; i < broken.length; i++) {
            vm.prank(ADMIN);
            apps.setDataRegistry(broken[i]);
            assertEq(apps.dataRegistry(), broken[i]);
            vm.prank(APP_OWNER);
            vm.expectRevert(AppRegistry.NotRegisteredGlobally.selector);
            apps.registerApp(APP, TERMS_V1, "", 0);
        }
    }

    /// The two registries together: a publisher can commit only once they are
    /// registered, added, and joined — and loses it when the owner ejects them.
    function test_commits_follow_app_membership_end_to_end() public {
        bytes32 sub = keccak256("docs");
        bytes32 root = bytes32(uint256(7));
        openApp();

        // Registered and invited is not enough.
        vm.prank(PUBLISHER);
        vm.expectRevert(DataRegistry.NotRegisteredForApp.selector);
        data.commitStateRoot(APP, sub, bytes32(0), root);

        join(PUBLISHER, APP, TERMS_V1, FEE);
        vm.prank(PUBLISHER);
        data.commitStateRoot(APP, sub, bytes32(0), root);
        assertEq(data.getNamespaceHead(APP, PUBLISHER, sub), root);

        vm.prank(APP_OWNER);
        apps.suspendForApp(APP, PUBLISHER);
        vm.prank(PUBLISHER);
        vm.expectRevert(DataRegistry.NotRegisteredForApp.selector);
        data.commitStateRoot(APP, sub, root, bytes32(uint256(8)));
    }

    // ── migration ─────────────────────────────────────────────────────────────

    /// The admin recreates an app for its owner: no fee is pulled, and it is stamped
    /// as paid now.
    function test_a_seeded_app_is_paid_up_without_paying() public {
        vm.prank(ADMIN);
        apps.setSubscriptionFee(SUB_FEE);
        // The token would refuse: seeding must not call it.
        usdc.setMode(MockUSDC.Mode.Revert);

        vm.prank(APP_OWNER);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.seedApp(APP, APP_OWNER, TERMS_V1, "https://tabs.example/terms", FEE, "ipfs://card");

        vm.warp(1_700_000_000);
        vm.startPrank(ADMIN);
        vm.expectRevert(AppRegistry.AppNotFound.selector);
        apps.seedApp(APP, address(0), TERMS_V1, "", 0, "");
        apps.seedApp(APP, APP_OWNER, TERMS_V1, "https://tabs.example/terms", FEE, "ipfs://card");
        assertEq(usdc.calls(), 0);

        (bool registered, address owner, uint64 paidAt) = apps.access(APP, APP_OWNER);
        assertTrue(registered);
        assertEq(owner, APP_OWNER);
        assertEq(paidAt, 1_700_000_000);
        assertEq(apps.appTermsUri(APP), "https://tabs.example/terms");
        assertEq(apps.appFee(APP), FEE);
        assertEq(apps.appAgentUri(APP), "ipfs://card");

        // A claimed app is never rewritten, whoever claimed it.
        vm.expectRevert(AppRegistry.AppAlreadyRegistered.selector);
        apps.seedApp(APP, STRANGER, TERMS_V2, "", 0, "");
        vm.stopPrank();
        assertEq(apps.getAppOwner(APP), APP_OWNER);

        // The owner really owns it.
        vm.prank(APP_OWNER);
        apps.setAppFee(APP, 0);
    }

    /// A membership is restored verbatim, once, and only into an app that exists.
    function test_a_seeded_membership_is_restored_verbatim() public {
        bytes32 sub = keccak256("docs");
        bytes32 root = bytes32(uint256(7));

        vm.startPrank(ADMIN);
        vm.expectRevert(AppRegistry.AppNotFound.selector);
        apps.seedPublisherForApp(GHOST_APP, PUBLISHER, STATUS_ACTIVE, TERMS_V1);
        apps.seedApp(APP, APP_OWNER, TERMS_V2, "", FEE, "");
        vm.stopPrank();

        vm.prank(APP_OWNER);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.seedPublisherForApp(APP, PUBLISHER, STATUS_ACTIVE, TERMS_V2);

        vm.startPrank(ADMIN);
        apps.seedPublisherForApp(APP, PUBLISHER, STATUS_ACTIVE, TERMS_V2);
        // Someone who accepted older terms stays on them, and so stays unregistered.
        apps.seedPublisherForApp(APP, STRANGER, STATUS_ACTIVE, TERMS_V1);
        vm.expectRevert(AppRegistry.AlreadyRegistered.selector);
        apps.seedPublisherForApp(APP, PUBLISHER, STATUS_INVITED, TERMS_V2);
        // The owner is already a member of their own app.
        vm.expectRevert(AppRegistry.AlreadyRegistered.selector);
        apps.seedPublisherForApp(APP, APP_OWNER, STATUS_INVITED, bytes32(0));
        vm.stopPrank();

        assertTrue(apps.isRegisteredForApp(APP, PUBLISHER));
        assertFalse(apps.isRegisteredForApp(APP, STRANGER));
        assertEq(apps.acceptedTerms(APP, STRANGER), TERMS_V1);

        // Restored without paying the join fee, and able to publish.
        vm.prank(PUBLISHER);
        data.commitStateRoot(APP, sub, bytes32(0), root);
        assertEq(data.getNamespaceHead(APP, PUBLISHER, sub), root);
    }

    // ── upgrades ──────────────────────────────────────────────────────────────

    /// The point of the proxy: a new implementation takes over the same address and
    /// the same state, and only the admin can install one.
    function test_an_upgrade_keeps_state_and_only_the_admin_can_do_it() public {
        openApp();
        join(PUBLISHER, APP, TERMS_V1, FEE);
        uint64 paidAt = apps.subscribedAt(APP);
        address v2 = address(new AppRegistryUpgradeMock());

        vm.prank(APP_OWNER);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.upgradeToAndCall(v2, "");

        vm.prank(ADMIN);
        apps.upgradeToAndCall(v2, "");

        assertEq(AppRegistryUpgradeMock(address(apps)).version(), 2);
        assertEq(apps.admin(), ADMIN);
        assertEq(apps.dataRegistry(), address(data));
        assertEq(apps.getAppOwner(APP), APP_OWNER);
        assertEq(apps.appTerms(APP), TERMS_V1);
        assertEq(apps.appTermsUri(APP), "https://tabs.example/terms");
        assertEq(apps.appFee(APP), FEE);
        assertEq(apps.subscribedAt(APP), paidAt);
        assertTrue(apps.isRegisteredForApp(APP, PUBLISHER));

        // Still the contract the DataRegistry asks, and still writable.
        vm.prank(PUBLISHER);
        data.commitStateRoot(APP, keccak256("docs"), bytes32(0), bytes32(uint256(7)));
        vm.prank(APP_OWNER);
        apps.renewApp(APP);
    }

    /// `initialize` stands in for the constructor, so it runs exactly once — and never
    /// on the bare implementation, which nobody should be able to take over.
    function test_initialize_runs_once_and_never_on_the_implementation() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        apps.initialize(STRANGER, address(usdc), 0, address(data));

        AppRegistry implementation = new AppRegistry();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(STRANGER, address(usdc), 0, address(data));
    }

    /// The admin role moves, and the right to upgrade moves with it.
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
