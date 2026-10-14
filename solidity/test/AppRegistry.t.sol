// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AppRegistry} from "../src/AppRegistry.sol";
import {DataRegistry} from "../src/DataRegistry.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC5643} from "../src/IERC5643.sol";
import {MockUSDC, Proxied} from "./Mocks.sol";

/// An app owner that cannot receive ETH.
contract PennilessOwner {
    function claim(AppRegistry apps, bytes32 app, bytes32 terms, uint256 fee, address invitee) external {
        apps.registerApp(app, terms, "", fee, 0);
        apps.invitePublisher(app, invitee);
    }

    function withdraw(AppRegistry apps, address to) external {
        apps.withdrawJoinFees(to);
    }
}

/// An app owner that, when its join fees reach it, tries to commit to its own app in the
/// middle of the withdrawal. As the owner it passes every membership check, so only the
/// reentrancy guard can refuse the commit. It keeps the refusal and accepts the fees, so
/// the withdrawal itself goes through.
contract ReentrantOwner {
    AppRegistry apps;
    bytes32 app;
    bytes public refusal;

    function claim(AppRegistry apps_, bytes32 app_, bytes32 terms, uint256 fee, address invitee) external {
        apps = apps_;
        app = app_;
        apps_.registerApp(app_, terms, "", fee, 0);
        apps_.invitePublisher(app_, invitee);
    }

    function withdraw() external {
        apps.withdrawJoinFees(address(this));
    }

    receive() external payable {
        try apps.commitStateRoot(app, keccak256("docs"), bytes32(0), bytes32(uint256(7))) {}
        catch (bytes memory reason) {
            refusal = reason;
        }
    }
}

/// What an upgrade installs: the same contract, plus one function to tell it by.
contract AppRegistryUpgradeMock is AppRegistry {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// Against the real DataRegistry rather than a mock of it. The tests assert that ETH
/// actually moves, and that a revert unwinds state.
contract AppRegistryTest is Test {
    address constant ADMIN = 0x1111111111111111111111111111111111111111;
    address constant APP_OWNER = 0x2222222222222222222222222222222222222222;
    address constant PUBLISHER = 0x3333333333333333333333333333333333333333;
    address constant STRANGER = 0x4444444444444444444444444444444444444444;

    bytes32 constant APP = bytes32(uint256(0xAA));
    bytes32 constant OTHER_APP = bytes32(uint256(0xBB));
    bytes32 constant GHOST_APP = bytes32(uint256(0xCC));
    bytes32 constant TERMS_V1 = bytes32(uint256(0x11));
    bytes32 constant TERMS_V2 = bytes32(uint256(0x22));
    uint256 constant FEE = 0.001 ether;
    uint256 constant SUB_FEE = 2_000_000; // 2 USDC (6 decimals)
    uint64 constant PERIOD = 30 days;
    uint64 constant T0 = 1_700_000_000;

    uint8 constant STATUS_NONE = 0;
    uint8 constant STATUS_ACTIVE = 1;
    uint8 constant STATUS_INVITED = 3;

    AppRegistry apps;
    DataRegistry data;
    MockUSDC usdc;

    /// Both registries, wired to each other. The subscription fee starts at zero.
    /// Nobody registers anywhere: the three everyday wallets only hold ETH.
    function setUp() public {
        usdc = new MockUSDC();
        apps = Proxied.appRegistry(ADMIN, address(usdc), 0, PERIOD);
        data = Proxied.dataRegistry(ADMIN, address(apps));
        vm.prank(ADMIN);
        apps.setDataRegistry(address(data));

        address[3] memory everyday = [APP_OWNER, PUBLISHER, STRANGER];
        for (uint256 i = 0; i < everyday.length; i++) {
            vm.deal(everyday[i], 10 ether);
        }
    }

    /// APP claimed by APP_OWNER, with terms and a join fee, and PUBLISHER invited —
    /// ready for PUBLISHER to join.
    function openApp() internal {
        vm.startPrank(APP_OWNER);
        apps.registerApp(APP, TERMS_V1, "https://tabs.example/terms", FEE, 0);
        apps.invitePublisher(APP, PUBLISHER);
        vm.stopPrank();
    }

    function join(address who, bytes32 app, bytes32 terms, uint256 value) internal {
        vm.prank(who);
        apps.joinApp{value: value}(app, terms);
    }

    // ── apps ──────────────────────────────────────────────────────────────────

    function test_only_the_app_owner_sets_terms_and_fee() public {
        openApp();
        assertEq(apps.getAppOwner(APP), APP_OWNER);

        vm.startPrank(STRANGER);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.setAppTerms(APP, TERMS_V2, "");
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.setJoinFee(APP, FEE);
        vm.expectRevert(AppRegistry.AppAlreadyRegistered.selector);
        apps.registerApp(APP, TERMS_V2, "", 0, 0);
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
        apps.invitePublisher(GHOST_APP, PUBLISHER);

        vm.prank(PUBLISHER);
        vm.expectRevert(AppRegistry.AppNotFound.selector);
        apps.joinApp(GHOST_APP, TERMS_V1);
    }

    function test_an_app_owner_is_their_own_first_publisher() public {
        openApp();
        assertTrue(apps.canPublish(APP, APP_OWNER));

        // ...and editing the terms must not lock them out of their own app either.
        vm.prank(APP_OWNER);
        apps.setAppTerms(APP, TERMS_V2, "");
        assertTrue(apps.canPublish(APP, APP_OWNER));
        assertEq(apps.acceptedTerms(APP, APP_OWNER), TERMS_V2);

        // Claiming an app must not enrol you anywhere else.
        assertFalse(apps.canPublish(OTHER_APP, APP_OWNER));
    }

    function test_moving_the_agent_card_leaves_memberships_alone() public {
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

        // The exact trap this field exists to avoid: the card moved, and everyone can
        // still publish.
        assertEq(apps.appTerms(APP), TERMS_V1);
        assertEq(apps.acceptedTerms(APP, PUBLISHER), TERMS_V1);
        assertTrue(apps.canPublish(APP, PUBLISHER));
        assertEq(apps.appAgentUri(OTHER_APP), "");
    }

    function test_the_admin_can_take_down_a_whole_app() public {
        openApp();
        vm.prank(APP_OWNER);
        apps.registerApp(OTHER_APP, TERMS_V1, "", 0, 0);
        join(PUBLISHER, APP, TERMS_V1, FEE);

        // The app owner has no say over their own takedown, and a stranger even less.
        vm.prank(APP_OWNER);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.setAppSuspended(APP, true);
        vm.prank(STRANGER);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.setAppSuspended(APP, true);

        vm.startPrank(ADMIN);
        vm.expectRevert(AppRegistry.AppNotFound.selector);
        apps.setAppSuspended(GHOST_APP, true);
        apps.setAppSuspended(APP, true);
        vm.stopPrank();
        assertTrue(apps.isAppSuspended(APP));

        // Everyone is out, owner included, and nothing about the other app moved.
        assertFalse(apps.canPublish(APP, PUBLISHER));
        assertFalse(apps.canPublish(APP, APP_OWNER));
        assertTrue(apps.canPublish(OTHER_APP, APP_OWNER));

        // No joining a suspended app, and per-publisher status is untouched underneath.
        vm.prank(APP_OWNER);
        apps.invitePublisher(APP, STRANGER);
        vm.prank(STRANGER);
        vm.expectRevert(AppRegistry.AppSuspended.selector);
        apps.joinApp{value: FEE}(APP, TERMS_V1);
        assertEq(uint8(apps.statusForApp(APP, PUBLISHER)), STATUS_ACTIVE);

        // Reinstating restores the memberships exactly as they were.
        vm.prank(ADMIN);
        apps.setAppSuspended(APP, false);
        assertTrue(apps.canPublish(APP, PUBLISHER));
        assertTrue(apps.canPublish(APP, APP_OWNER));
    }

    // ── joining ───────────────────────────────────────────────────────────────

    function test_only_an_invited_publisher_can_join() public {
        openApp();

        // An invitation is not a membership.
        assertEq(uint8(apps.statusForApp(APP, PUBLISHER)), STATUS_INVITED);
        assertFalse(apps.canPublish(APP, PUBLISHER));

        vm.startPrank(STRANGER);
        vm.expectRevert(AppRegistry.NotInvited.selector);
        apps.joinApp{value: FEE}(APP, TERMS_V1);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.invitePublisher(APP, STRANGER);
        vm.stopPrank();

        vm.startPrank(APP_OWNER);
        vm.expectRevert(AppRegistry.AlreadyInApp.selector);
        apps.invitePublisher(APP, PUBLISHER);

        // The owner can take an invitation back before it is used.
        apps.invitePublisher(APP, STRANGER);
        apps.revokeInvitation(APP, STRANGER);
        vm.stopPrank();
        vm.prank(STRANGER);
        vm.expectRevert(AppRegistry.NotInvited.selector);
        apps.joinApp{value: FEE}(APP, TERMS_V1);
    }

    function test_joining_agrees_to_an_exact_terms_version() public {
        // An app always has terms, so there is always something to agree to: zero is
        // refused when the app is claimed, and when its terms change.
        vm.prank(APP_OWNER);
        vm.expectRevert(AppRegistry.TermsNotSet.selector);
        apps.registerApp(OTHER_APP, bytes32(0), "", 0, 0);
        assertEq(apps.getAppOwner(OTHER_APP), address(0));

        openApp();
        vm.prank(APP_OWNER);
        vm.expectRevert(AppRegistry.TermsNotSet.selector);
        apps.setAppTerms(APP, bytes32(0), "");
        assertEq(apps.appTerms(APP), TERMS_V1);

        // The wrong version reverts: an owner must not be able to swap the terms
        // under a pending join and have it land as consent to the new ones.
        vm.prank(PUBLISHER);
        vm.expectRevert(AppRegistry.TermsMismatch.selector);
        apps.joinApp{value: FEE}(APP, TERMS_V2);

        join(PUBLISHER, APP, TERMS_V1, FEE);
        assertTrue(apps.canPublish(APP, PUBLISHER));
        assertEq(apps.acceptedTerms(APP, PUBLISHER), TERMS_V1);

        // Idempotence: no paying twice for the same membership.
        vm.prank(PUBLISHER);
        vm.expectRevert(AppRegistry.AlreadyJoined.selector);
        apps.joinApp{value: FEE}(APP, TERMS_V1);
    }

    function test_the_fee_is_required_and_goes_to_the_app_owner() public {
        openApp();

        // Exactly the fee: less is refused, and so is more, which would otherwise reach
        // the owner unrecorded.
        uint256[2] memory wrong = [FEE - 1, FEE + 1];
        for (uint256 i = 0; i < wrong.length; i++) {
            vm.prank(PUBLISHER);
            vm.expectRevert(AppRegistry.JoinFeeMismatch.selector);
            apps.joinApp{value: wrong[i]}(APP, TERMS_V1);
        }

        // The fee is the owner's, held until they take it out.
        uint256 ownerBefore = APP_OWNER.balance;
        join(PUBLISHER, APP, TERMS_V1, FEE);
        assertTrue(apps.canPublish(APP, PUBLISHER));
        assertEq(apps.joinFeesOwed(APP_OWNER), FEE);
        assertEq(address(apps).balance, FEE);

        // Accepting updated terms is free, so the owner is owed nothing more.
        vm.prank(APP_OWNER);
        apps.setAppTerms(APP, TERMS_V2, "");
        vm.prank(PUBLISHER);
        apps.acceptUpdatedTerms(APP, TERMS_V2);
        assertEq(apps.joinFeesOwed(APP_OWNER), FEE);

        // Only the owner takes it out, all of it, once.
        vm.prank(STRANGER);
        vm.expectRevert(AppRegistry.NothingToWithdraw.selector);
        apps.withdrawJoinFees(STRANGER);
        vm.expectEmit(true, true, true, true, address(apps));
        emit AppRegistry.JoinFeesWithdrawn(APP_OWNER, APP_OWNER, FEE);
        vm.prank(APP_OWNER);
        apps.withdrawJoinFees(APP_OWNER);
        assertEq(APP_OWNER.balance, ownerBefore + FEE, "the join fee did not reach the app owner");
        assertEq(apps.joinFeesOwed(APP_OWNER), 0);
        assertEq(address(apps).balance, 0, "the registry kept a join fee it no longer owes");
        vm.prank(APP_OWNER);
        vm.expectRevert(AppRegistry.NothingToWithdraw.selector);
        apps.withdrawJoinFees(APP_OWNER);
    }

    /// One balance per owner, across all of their apps.
    function test_an_owner_withdraws_the_fees_of_all_their_apps_at_once() public {
        openApp();
        vm.startPrank(APP_OWNER);
        apps.registerApp(OTHER_APP, TERMS_V1, "", 2 * FEE, 0);
        apps.invitePublisher(OTHER_APP, PUBLISHER);
        vm.stopPrank();
        join(PUBLISHER, APP, TERMS_V1, FEE);
        join(PUBLISHER, OTHER_APP, TERMS_V1, 2 * FEE);
        assertEq(apps.joinFeesOwed(APP_OWNER), 3 * FEE);

        vm.prank(APP_OWNER);
        apps.withdrawJoinFees(STRANGER);
        assertEq(STRANGER.balance, 10 ether + 3 * FEE);
        assertEq(address(apps).balance, 0);
    }

    /// Joining never runs the owner's code, so an owner that cannot take ETH cannot
    /// block joins. Its fees wait until it names an address that can.
    function test_an_owner_that_cannot_take_eth_still_gets_its_fees() public {
        PennilessOwner owner = new PennilessOwner();
        owner.claim(apps, OTHER_APP, TERMS_V1, FEE, PUBLISHER);
        join(PUBLISHER, OTHER_APP, TERMS_V1, FEE);
        assertTrue(apps.canPublish(OTHER_APP, PUBLISHER));

        // Sent to itself, the withdrawal fails, and the fee stays owed.
        vm.expectRevert(AppRegistry.TransferFailed.selector);
        owner.withdraw(apps, address(owner));
        assertEq(apps.joinFeesOwed(address(owner)), FEE);

        owner.withdraw(apps, STRANGER);
        assertEq(STRANGER.balance, 10 ether + FEE);
        assertEq(apps.joinFeesOwed(address(owner)), 0);
    }

    /// Withdrawing join fees hands control to the recipient. A guarded function called
    /// from there is refused, even one the owner could otherwise call: committing to
    /// their own app.
    function test_a_join_fee_payout_cannot_reenter() public {
        ReentrantOwner owner = new ReentrantOwner();
        owner.claim(apps, OTHER_APP, TERMS_V1, FEE, PUBLISHER);
        assertTrue(apps.canPublish(OTHER_APP, address(owner)));

        join(PUBLISHER, OTHER_APP, TERMS_V1, FEE);
        owner.withdraw();
        assertEq(
            owner.refusal(), abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(data.getNamespaceHead(OTHER_APP, address(owner), keccak256("docs")), bytes32(0));
        assertEq(address(owner).balance, FEE);
        assertTrue(apps.canPublish(OTHER_APP, PUBLISHER));

        // Outside the payout, the same commit goes through.
        vm.prank(address(owner));
        apps.commitStateRoot(OTHER_APP, keccak256("docs"), bytes32(0), bytes32(uint256(7)));
        assertEq(data.getNamespaceHead(OTHER_APP, address(owner), keccak256("docs")), bytes32(uint256(7)));
    }

    function test_moving_the_terms_drops_everyone_back_to_unaccepted() public {
        openApp();
        join(PUBLISHER, APP, TERMS_V1, FEE);

        vm.prank(APP_OWNER);
        apps.setAppTerms(APP, TERMS_V2, "https://tabs.example/terms-v2");

        // Cannot publish any more — but distinguishably so: still ACTIVE, on a stale
        // hash. A UI that only had the boolean would say "you were never here".
        assertFalse(apps.canPublish(APP, PUBLISHER));
        assertEq(uint8(apps.statusForApp(APP, PUBLISHER)), STATUS_ACTIVE);
        assertEq(apps.acceptedTerms(APP, PUBLISHER), TERMS_V1);

        // Accepting the update is free. An app must not be able to bill its whole
        // publisher base by editing a sentence.
        vm.prank(PUBLISHER);
        apps.acceptUpdatedTerms(APP, TERMS_V2);
        assertTrue(apps.canPublish(APP, PUBLISHER));
    }

    /// Joining is once, and paid; accepting updated terms is for members, and free.
    /// Each refuses what belongs to the other.
    function test_joining_and_accepting_updated_terms_are_separate() public {
        openApp();

        // An invited publisher has nothing to update: they join.
        vm.prank(PUBLISHER);
        vm.expectRevert(AppRegistry.NotJoined.selector);
        apps.acceptUpdatedTerms(APP, TERMS_V1);

        join(PUBLISHER, APP, TERMS_V1, FEE);
        vm.prank(PUBLISHER);
        vm.expectRevert(AppRegistry.TermsAlreadyAccepted.selector);
        apps.acceptUpdatedTerms(APP, TERMS_V1);

        vm.prank(APP_OWNER);
        apps.setAppTerms(APP, TERMS_V2, "");

        // A member does not join again, with or without paying.
        vm.startPrank(PUBLISHER);
        vm.expectRevert(AppRegistry.AlreadyJoined.selector);
        apps.joinApp(APP, TERMS_V2);
        vm.expectRevert(AppRegistry.AlreadyJoined.selector);
        apps.joinApp{value: FEE}(APP, TERMS_V2);
        // Only the current terms can be accepted.
        vm.expectRevert(AppRegistry.TermsMismatch.selector);
        apps.acceptUpdatedTerms(APP, TERMS_V1);

        vm.expectEmit(true, true, true, true, address(apps));
        emit AppRegistry.UpdatedTermsAccepted(APP, PUBLISHER, TERMS_V2);
        apps.acceptUpdatedTerms(APP, TERMS_V2);
        vm.stopPrank();
        assertEq(apps.acceptedTerms(APP, PUBLISHER), TERMS_V2);
        assertTrue(apps.canPublish(APP, PUBLISHER));

        // It takes no ETH: the call is refused before any code runs.
        vm.prank(PUBLISHER);
        (bool ok,) = address(apps).call{value: 1}(abi.encodeCall(AppRegistry.acceptUpdatedTerms, (APP, TERMS_V2)));
        assertFalse(ok);
    }

    function test_membership_is_per_app() public {
        openApp();
        vm.prank(APP_OWNER);
        apps.registerApp(OTHER_APP, TERMS_V2, "", 0, 0);
        join(PUBLISHER, APP, TERMS_V1, FEE);

        assertTrue(apps.canPublish(APP, PUBLISHER));
        assertFalse(apps.canPublish(OTHER_APP, PUBLISHER));
        assertFalse(apps.canPublish(APP, STRANGER));
    }

    function test_an_app_owner_can_eject_a_publisher_from_their_app_only() public {
        openApp();
        vm.startPrank(APP_OWNER);
        apps.registerApp(OTHER_APP, TERMS_V1, "", 0, 0);
        apps.invitePublisher(OTHER_APP, PUBLISHER);
        vm.stopPrank();
        join(PUBLISHER, APP, TERMS_V1, FEE);
        join(PUBLISHER, OTHER_APP, TERMS_V1, 0);

        vm.prank(STRANGER);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.setPublisherSuspended(APP, PUBLISHER, true);

        vm.prank(APP_OWNER);
        apps.setPublisherSuspended(APP, PUBLISHER, true);
        assertFalse(apps.canPublish(APP, PUBLISHER));
        assertTrue(apps.canPublish(OTHER_APP, PUBLISHER), "one app's ban leaked into another");

        // Paying again is not a way back in.
        vm.prank(PUBLISHER);
        vm.expectRevert(AppRegistry.PublisherSuspendedApp.selector);
        apps.joinApp{value: FEE}(APP, TERMS_V1);

        vm.startPrank(APP_OWNER);
        // Only a member can be suspended, and only someone suspended reinstated. An
        // invitation is not suspended but taken back (`revokeInvitation`).
        vm.expectRevert(AppRegistry.NotInvited.selector);
        apps.setPublisherSuspended(APP, STRANGER, true);
        apps.invitePublisher(APP, STRANGER);
        vm.expectRevert(AppRegistry.NotJoined.selector);
        apps.setPublisherSuspended(APP, STRANGER, true);
        vm.expectRevert(AppRegistry.PublisherNotSuspended.selector);
        apps.setPublisherSuspended(APP, STRANGER, false);
        vm.expectRevert(AppRegistry.PublisherNotSuspended.selector);
        apps.setPublisherSuspended(OTHER_APP, PUBLISHER, false);
        apps.setPublisherSuspended(APP, PUBLISHER, false);
        vm.stopPrank();
        assertTrue(apps.canPublish(APP, PUBLISHER));
    }

    /// An owner's membership of their own app is not theirs to suspend.
    function test_an_owner_cannot_suspend_themselves() public {
        openApp();
        vm.startPrank(APP_OWNER);
        vm.expectRevert(AppRegistry.CannotSuspendOwner.selector);
        apps.setPublisherSuspended(APP, APP_OWNER, true);
        vm.expectRevert(AppRegistry.PublisherNotSuspended.selector);
        apps.setPublisherSuspended(APP, APP_OWNER, false);
        vm.stopPrank();
        assertEq(uint8(apps.statusForApp(APP, APP_OWNER)), STATUS_ACTIVE);
        assertTrue(apps.canPublish(APP, APP_OWNER));
    }

    /// A revoked invitation is as if it had never been sent: the publisher cannot
    /// join, and can be invited again, joining and paying as anyone would.
    function test_revoking_an_invitation() public {
        openApp();

        vm.prank(STRANGER);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.revokeInvitation(APP, PUBLISHER);

        vm.expectEmit(true, true, true, true, address(apps));
        emit AppRegistry.PublisherInvitationRevoked(APP, PUBLISHER);
        vm.prank(APP_OWNER);
        apps.revokeInvitation(APP, PUBLISHER);
        assertEq(uint8(apps.statusForApp(APP, PUBLISHER)), STATUS_NONE);
        assertRefused(PUBLISHER, APP, AppRegistry.NotInvited.selector);
        vm.prank(PUBLISHER);
        vm.expectRevert(AppRegistry.NotInvited.selector);
        apps.joinApp{value: FEE}(APP, TERMS_V1);

        vm.startPrank(APP_OWNER);
        // Nothing left to revoke, and a member's membership is not an invitation.
        vm.expectRevert(AppRegistry.NotInvited.selector);
        apps.revokeInvitation(APP, PUBLISHER);
        vm.expectRevert(AppRegistry.AlreadyJoined.selector);
        apps.revokeInvitation(APP, APP_OWNER);
        apps.invitePublisher(APP, PUBLISHER);
        vm.stopPrank();

        join(PUBLISHER, APP, TERMS_V1, FEE);
        assertTrue(apps.canPublish(APP, PUBLISHER));
        vm.prank(APP_OWNER);
        vm.expectRevert(AppRegistry.AlreadyJoined.selector);
        apps.revokeInvitation(APP, PUBLISHER);
    }

    function test_join_info_answers_a_join_screen_in_one_call() public {
        openApp();
        (bytes32 hash, string memory uri, uint256 fee, AppRegistry.Status status, bool allowed) =
            apps.joinInfo(APP, PUBLISHER);
        assertEq(hash, TERMS_V1);
        assertEq(uri, "https://tabs.example/terms");
        assertEq(fee, FEE);
        assertEq(uint8(status), STATUS_INVITED);
        assertFalse(allowed);

        (,,, AppRegistry.Status strangerStatus,) = apps.joinInfo(APP, STRANGER);
        assertEq(uint8(strangerStatus), STATUS_NONE);
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
            apps.registerApp(OTHER_APP, TERMS_V1, "", 0, SUB_FEE);
            assertEq(apps.getAppOwner(OTHER_APP), address(0), "an unpaid claim left an app behind");
            assertEq(apps.balanceOf(STRANGER), 0, "an unpaid claim minted a token");
        }
        usdc.setMode(MockUSDC.Mode.Ok);

        vm.warp(T0);
        vm.expectEmit(true, true, true, true, address(apps));
        emit IERC5643.SubscriptionUpdate(uint256(APP), T0 + PERIOD);
        vm.prank(APP_OWNER);
        apps.registerApp(APP, TERMS_V1, "", 0, SUB_FEE);
        assertEq(apps.expiresAt(uint256(APP)), T0 + PERIOD);
        // The fee was pulled from the claimer into the registry.
        assertEq(usdc.lastFrom(), APP_OWNER);
        assertEq(usdc.lastTo(), address(apps));
        assertEq(usdc.lastAmount(), SUB_FEE);

        // The gate's one read: membership, who owns the app, and when it expires.
        (bool allowed, address owner, uint64 expiry) = apps.access(APP, APP_OWNER);
        assertTrue(allowed);
        assertEq(owner, APP_OWNER);
        assertEq(expiry, T0 + PERIOD);
        (allowed, owner, expiry) = apps.access(APP, STRANGER);
        assertFalse(allowed);
        assertEq(owner, APP_OWNER);
        (allowed, owner, expiry) = apps.access(OTHER_APP, STRANGER);
        assertFalse(allowed);
        assertEq(owner, address(0));
        assertEq(expiry, 0);

        // The claimer caps what they pay: a fee raised above the cap refuses the claim,
        // and one under it charges the fee, not the cap.
        vm.prank(STRANGER);
        vm.expectRevert(AppRegistry.SubscriptionFeeTooHigh.selector);
        apps.registerApp(OTHER_APP, TERMS_V1, "", 0, SUB_FEE - 1);
        vm.prank(STRANGER);
        apps.registerApp(OTHER_APP, TERMS_V1, "", 0, SUB_FEE * 10);
        assertEq(usdc.lastAmount(), SUB_FEE);
    }

    function test_a_free_subscription_never_touches_the_token() public {
        // Fee is zero and the token would revert: the claim must not call it.
        usdc.setMode(MockUSDC.Mode.Revert);
        vm.prank(APP_OWNER);
        apps.registerApp(APP, TERMS_V1, "", 0, 0);
        assertEq(apps.getAppOwner(APP), APP_OWNER);
        assertEq(usdc.calls(), 0);
    }

    // ── the app's token (ERC-721, ERC-5643) ───────────────────────────────────

    function test_claiming_mints_the_apps_token() public {
        vm.expectEmit(true, true, true, true, address(apps));
        emit IERC721.Transfer(address(0), APP_OWNER, uint256(APP));
        openApp();
        assertEq(apps.ownerOf(uint256(APP)), APP_OWNER);
        assertEq(apps.balanceOf(APP_OWNER), 1);
        assertEq(apps.name(), "FAPP");
        assertEq(apps.symbol(), "FAPP");

        assertTrue(apps.supportsInterface(0x01ffc9a7), "ERC-165");
        assertTrue(apps.supportsInterface(0x80ac58cd), "ERC-721");
        assertTrue(apps.supportsInterface(0x5b5e139f), "ERC-721 metadata");
        assertTrue(apps.supportsInterface(0x8c65f84d), "ERC-5643");
        assertEq(type(IERC5643).interfaceId, bytes4(0x8c65f84d));
        assertFalse(apps.supportsInterface(0xffffffff));

        // No token, no answer: the standard's reads revert for an unknown token.
        bytes memory unknown = abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, uint256(GHOST_APP));
        vm.expectRevert(unknown);
        apps.expiresAt(uint256(GHOST_APP));
        vm.expectRevert(unknown);
        apps.isRenewable(uint256(GHOST_APP));
    }

    /// The token stays with the app's owner: no transfer, by its owner or anyone they
    /// approve, so it can never disagree with `getAppOwner`.
    function test_an_apps_token_cannot_be_transferred() public {
        openApp();
        vm.startPrank(APP_OWNER);
        vm.expectRevert(AppRegistry.NotTransferable.selector);
        apps.transferFrom(APP_OWNER, STRANGER, uint256(APP));
        vm.expectRevert(AppRegistry.NotTransferable.selector);
        apps.safeTransferFrom(APP_OWNER, STRANGER, uint256(APP));
        apps.approve(STRANGER, uint256(APP));
        vm.stopPrank();
        vm.prank(STRANGER);
        vm.expectRevert(AppRegistry.NotTransferable.selector);
        apps.transferFrom(APP_OWNER, STRANGER, uint256(APP));

        assertEq(apps.ownerOf(uint256(APP)), APP_OWNER);
        assertEq(apps.getAppOwner(APP), APP_OWNER);
    }

    /// A renewal adds one period to the expiry, and only once less than a period is
    /// left: an owner cannot pay several periods ahead.
    function test_a_renewal_extends_the_expiry_by_one_period() public {
        vm.warp(T0);
        openApp();
        vm.prank(ADMIN);
        apps.setSubscriptionFee(SUB_FEE);

        // A full period is left at claim: not yet.
        assertFalse(apps.isRenewable(uint256(APP)));
        vm.prank(APP_OWNER);
        vm.expectRevert(AppRegistry.SubscriptionNotRenewable.selector);
        apps.renewSubscription(uint256(APP), PERIOD);

        vm.warp(T0 + 1);
        assertTrue(apps.isRenewable(uint256(APP)));
        vm.expectEmit(true, true, true, true, address(apps));
        emit IERC5643.SubscriptionUpdate(uint256(APP), T0 + 2 * PERIOD);
        vm.prank(APP_OWNER);
        apps.renewSubscription(uint256(APP), PERIOD);
        assertEq(apps.expiresAt(uint256(APP)), T0 + 2 * PERIOD, "extended from the expiry, not from now");
        assertEq(usdc.lastFrom(), APP_OWNER);
        assertEq(usdc.lastAmount(), SUB_FEE);

        // Paid a period ahead: no more until less than a period is left again.
        vm.prank(APP_OWNER);
        vm.expectRevert(AppRegistry.SubscriptionNotRenewable.selector);
        apps.renewSubscription(uint256(APP), PERIOD);
        vm.warp(T0 + PERIOD + 1);
        assertTrue(apps.isRenewable(uint256(APP)));
    }

    /// After the expiry has passed, a renewal starts a full period from now: the time
    /// spent lapsed is not paid for.
    function test_a_lapsed_subscription_renews_from_now() public {
        vm.warp(T0);
        openApp();
        vm.warp(T0 + PERIOD + 1000);
        vm.prank(APP_OWNER);
        apps.renewSubscription(uint256(APP), PERIOD);
        assertEq(apps.expiresAt(uint256(APP)), T0 + 2 * PERIOD + 1000);
    }

    function test_a_renewal_is_one_period_by_the_owner_or_their_approved() public {
        vm.warp(T0);
        openApp();
        vm.warp(T0 + 1);

        vm.startPrank(APP_OWNER);
        vm.expectRevert(AppRegistry.DurationMismatch.selector);
        apps.renewSubscription(uint256(APP), PERIOD - 1);
        vm.expectRevert(AppRegistry.DurationMismatch.selector);
        apps.renewSubscription(uint256(APP), 2 * PERIOD);
        // The fee is USDC: ETH sent with it would be stuck.
        vm.expectRevert(AppRegistry.EthNotAccepted.selector);
        apps.renewSubscription{value: 1}(uint256(APP), PERIOD);
        vm.stopPrank();

        vm.prank(STRANGER);
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, STRANGER, uint256(APP))
        );
        apps.renewSubscription(uint256(APP), PERIOD);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, uint256(GHOST_APP)));
        apps.renewSubscription(uint256(GHOST_APP), PERIOD);

        // Someone the owner approves may renew, and pays.
        vm.prank(ADMIN);
        apps.setSubscriptionFee(SUB_FEE);
        vm.prank(APP_OWNER);
        apps.approve(STRANGER, uint256(APP));
        vm.prank(STRANGER);
        apps.renewSubscription(uint256(APP), PERIOD);
        assertEq(apps.expiresAt(uint256(APP)), T0 + 2 * PERIOD);
        assertEq(usdc.lastFrom(), STRANGER);

        // ...but not end it: cancelling is the owner's alone.
        vm.prank(STRANGER);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.cancelSubscription(uint256(APP));
        vm.prank(APP_OWNER);
        apps.setApprovalForAll(STRANGER, true);
        vm.prank(STRANGER);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.cancelSubscription(uint256(APP));
        assertEq(apps.expiresAt(uint256(APP)), T0 + 2 * PERIOD);
    }

    /// Cancelling ends the subscription now, as the standard does: the expiry becomes
    /// zero. The app stays claimed, and a renewal starts over from now.
    function test_cancelling_ends_the_subscription_now() public {
        vm.warp(T0);
        openApp();

        vm.prank(STRANGER);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.cancelSubscription(uint256(APP));
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, uint256(GHOST_APP)));
        apps.cancelSubscription(uint256(GHOST_APP));
        vm.prank(APP_OWNER);
        vm.expectRevert(AppRegistry.EthNotAccepted.selector);
        apps.cancelSubscription{value: 1}(uint256(APP));

        vm.expectEmit(true, true, true, true, address(apps));
        emit IERC5643.SubscriptionUpdate(uint256(APP), 0);
        vm.prank(APP_OWNER);
        apps.cancelSubscription(uint256(APP));
        assertEq(apps.expiresAt(uint256(APP)), 0);
        (,, uint64 expiry) = apps.access(APP, APP_OWNER);
        assertEq(expiry, 0);
        assertEq(apps.getAppOwner(APP), APP_OWNER);

        assertTrue(apps.isRenewable(uint256(APP)));
        vm.warp(T0 + 500);
        vm.prank(APP_OWNER);
        apps.renewSubscription(uint256(APP), PERIOD);
        assertEq(apps.expiresAt(uint256(APP)), T0 + 500 + PERIOD);
    }

    /// The admin sets the period. A change applies from each app's next payment and
    /// leaves expiries already set alone.
    function test_a_new_period_applies_from_the_next_payment() public {
        vm.warp(T0);
        openApp();
        uint64 week = 7 days;

        vm.prank(APP_OWNER);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.setSubscriptionPeriod(week);
        vm.prank(ADMIN);
        vm.expectRevert(AppRegistry.ZeroPeriod.selector);
        apps.setSubscriptionPeriod(0);

        vm.expectEmit(true, true, true, true, address(apps));
        emit AppRegistry.SubscriptionPeriodChanged(week);
        vm.prank(ADMIN);
        apps.setSubscriptionPeriod(week);
        assertEq(apps.subscriptionPeriod(), week);
        assertEq(apps.expiresAt(uint256(APP)), T0 + PERIOD, "an expiry already paid for moved");

        // Renewable once less than the new period is left, and for the new period only.
        vm.warp(T0 + PERIOD - week);
        assertFalse(apps.isRenewable(uint256(APP)));
        vm.warp(T0 + PERIOD - week + 1);
        vm.startPrank(APP_OWNER);
        vm.expectRevert(AppRegistry.DurationMismatch.selector);
        apps.renewSubscription(uint256(APP), PERIOD);
        apps.renewSubscription(uint256(APP), week);
        vm.stopPrank();
        assertEq(apps.expiresAt(uint256(APP)), T0 + PERIOD + week);

        // A new app is claimed for the new period.
        vm.prank(STRANGER);
        apps.registerApp(OTHER_APP, TERMS_V1, "", 0, 0);
        assertEq(apps.expiresAt(uint256(OTHER_APP)), block.timestamp + week);
    }

    function test_the_period_cannot_start_at_zero() public {
        address implementation = address(new AppRegistry());
        bytes memory init = abi.encodeCall(AppRegistry.initialize, (ADMIN, address(usdc), 0, 0));
        vm.expectRevert(AppRegistry.ZeroPeriod.selector);
        new ERC1967Proxy(implementation, init);
    }

    /// The admin sweeps the subscription fees, and any other token sent here by mistake.
    function test_only_the_admin_sweeps_tokens() public {
        vm.prank(APP_OWNER);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.withdrawToken(address(usdc), STRANGER, SUB_FEE);

        vm.expectEmit(true, true, true, true, address(apps));
        emit AppRegistry.TokenWithdrawn(address(usdc), STRANGER, SUB_FEE);
        vm.prank(ADMIN);
        apps.withdrawToken(address(usdc), STRANGER, SUB_FEE);
        assertEq(usdc.lastTo(), STRANGER);
        assertEq(usdc.lastAmount(), SUB_FEE);

        MockUSDC stray = new MockUSDC();
        vm.prank(ADMIN);
        apps.withdrawToken(address(stray), STRANGER, 5);
        assertEq(stray.lastTo(), STRANGER);
        assertEq(stray.lastAmount(), 5);

        usdc.setMode(MockUSDC.Mode.ReturnFalse);
        vm.prank(ADMIN);
        vm.expectRevert(AppRegistry.TransferFailed.selector);
        apps.withdrawToken(address(usdc), STRANGER, SUB_FEE);
    }

    // ── network-wide bans ─────────────────────────────────────────────────────

    /// A wallet that has never been seen can claim an app and be added to one: there
    /// is no registration step in front of either.
    function test_claiming_and_adding_need_no_registration() public {
        address newcomer = makeAddr("newcomer");

        vm.prank(newcomer);
        apps.registerApp(OTHER_APP, TERMS_V1, "", 0, 0);
        assertEq(apps.getAppOwner(OTHER_APP), newcomer);

        openApp();
        vm.prank(APP_OWNER);
        apps.invitePublisher(APP, newcomer);
        assertEq(uint8(apps.statusForApp(APP, newcomer)), STATUS_INVITED);
    }

    /// Only the admin bans and lifts a ban, any address can be banned, and one wallet's
    /// ban does not touch another's.
    function test_only_the_admin_bans_and_reinstates() public {
        vm.prank(STRANGER);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.setGlobalSuspension(STRANGER, true);
        assertFalse(apps.globalSuspensions(STRANGER));

        vm.expectEmit(true, true, true, true, address(apps));
        emit AppRegistry.GlobalSuspensionChanged(STRANGER, true);
        vm.prank(ADMIN);
        apps.setGlobalSuspension(STRANGER, true);
        assertTrue(apps.globalSuspensions(STRANGER));
        assertFalse(apps.globalSuspensions(PUBLISHER), "one wallet's ban leaked into another");

        // A banned wallet cannot lift its own ban.
        vm.prank(STRANGER);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.setGlobalSuspension(STRANGER, false);

        vm.expectEmit(true, true, true, true, address(apps));
        emit AppRegistry.GlobalSuspensionChanged(STRANGER, false);
        vm.prank(ADMIN);
        apps.setGlobalSuspension(STRANGER, false);
        assertFalse(apps.globalSuspensions(STRANGER));
    }

    /// The reason the check exists: a wallet the protocol admin banned network-wide
    /// cannot come back as an app owner, or be brought into an app by one.
    function test_a_globally_banned_wallet_can_neither_claim_nor_be_added() public {
        vm.prank(ADMIN);
        apps.setGlobalSuspension(STRANGER, true);

        vm.prank(STRANGER);
        vm.expectRevert(AppRegistry.PublisherSuspendedGlobal.selector);
        apps.registerApp(OTHER_APP, TERMS_V1, "", 0, 0);
        assertEq(apps.getAppOwner(OTHER_APP), address(0));

        openApp();
        vm.prank(APP_OWNER);
        vm.expectRevert(AppRegistry.PublisherSuspendedGlobal.selector);
        apps.invitePublisher(APP, STRANGER);
        assertEq(uint8(apps.statusForApp(APP, STRANGER)), STATUS_NONE);

        vm.prank(ADMIN);
        apps.setGlobalSuspension(STRANGER, false);
        vm.prank(APP_OWNER);
        apps.invitePublisher(APP, STRANGER);
        vm.prank(STRANGER);
        apps.registerApp(OTHER_APP, TERMS_V1, "", 0, 0);
    }

    /// An invitation does not outlast a ban: a wallet banned after the owner added it
    /// cannot accept, until the admin reinstates it.
    function test_a_globally_banned_wallet_cannot_join() public {
        openApp();
        vm.prank(ADMIN);
        apps.setGlobalSuspension(PUBLISHER, true);

        vm.prank(PUBLISHER);
        vm.expectRevert(AppRegistry.PublisherSuspendedGlobal.selector);
        apps.joinApp{value: FEE}(APP, TERMS_V1);
        assertEq(uint8(apps.statusForApp(APP, PUBLISHER)), STATUS_INVITED);

        vm.prank(ADMIN);
        apps.setGlobalSuspension(PUBLISHER, false);
        join(PUBLISHER, APP, TERMS_V1, FEE);
        assertTrue(apps.canPublish(APP, PUBLISHER));
    }

    /// Accepting updated terms runs the same checks, so a ban stops that too.
    function test_a_globally_banned_publisher_cannot_accept_new_terms() public {
        openApp();
        join(PUBLISHER, APP, TERMS_V1, FEE);
        vm.prank(APP_OWNER);
        apps.setAppTerms(APP, TERMS_V2, "");
        vm.prank(ADMIN);
        apps.setGlobalSuspension(PUBLISHER, true);

        vm.prank(PUBLISHER);
        vm.expectRevert(AppRegistry.PublisherSuspendedGlobal.selector);
        apps.acceptUpdatedTerms(APP, TERMS_V2);
        assertEq(apps.acceptedTerms(APP, PUBLISHER), TERMS_V1);
    }

    // ── publishing ────────────────────────────────────────────────────────────

    /// The two registries together: a publisher can commit only once they are added
    /// and joined — and loses it when the owner ejects them, or the admin bans them.
    function test_commits_follow_app_membership_end_to_end() public {
        bytes32 sub = keccak256("docs");
        bytes32 root = bytes32(uint256(7));
        openApp();

        // Invited is not enough.
        vm.prank(PUBLISHER);
        vm.expectRevert(AppRegistry.NotJoined.selector);
        apps.commitStateRoot(APP, sub, bytes32(0), root);

        join(PUBLISHER, APP, TERMS_V1, FEE);
        vm.prank(PUBLISHER);
        apps.commitStateRoot(APP, sub, bytes32(0), root);
        assertEq(data.getNamespaceHead(APP, PUBLISHER, sub), root);
        // Written under the sender only.
        assertEq(data.getNamespaceHead(APP, APP_OWNER, sub), bytes32(0));

        vm.prank(APP_OWNER);
        apps.setPublisherSuspended(APP, PUBLISHER, true);
        vm.prank(PUBLISHER);
        vm.expectRevert(AppRegistry.PublisherSuspendedApp.selector);
        apps.commitStateRoot(APP, sub, root, bytes32(uint256(8)));

        // A network-wide ban is part of the membership answer, so it stops an owner who
        // claimed the app before being banned, on every commit.
        vm.prank(APP_OWNER);
        apps.commitStateRoot(APP, sub, bytes32(0), root);
        vm.prank(ADMIN);
        apps.setGlobalSuspension(APP_OWNER, true);
        assertFalse(apps.canPublish(APP, APP_OWNER));
        vm.prank(APP_OWNER);
        vm.expectRevert(AppRegistry.PublisherSuspendedGlobal.selector);
        apps.commitStateRoot(APP, sub, root, bytes32(uint256(8)));

        // Lifting the ban touches nothing else: the timeline resumes from its head.
        vm.prank(ADMIN);
        apps.setGlobalSuspension(APP_OWNER, false);
        vm.prank(APP_OWNER);
        apps.commitStateRoot(APP, sub, root, bytes32(uint256(8)));
        assertEq(data.getNamespaceHead(APP, APP_OWNER, sub), bytes32(uint256(8)));
    }

    /// `who` may not commit to `app`, for the reason `err` names, and
    /// `canPublish` agrees.
    function assertRefused(address who, bytes32 app, bytes4 err) internal {
        assertFalse(apps.canPublish(app, who));
        vm.prank(who);
        vm.expectRevert(err);
        apps.commitStateRoot(app, keccak256("docs"), bytes32(0), bytes32(uint256(7)));
    }

    /// A refused commit says why, so the publisher knows whom to ask: the app owner,
    /// the protocol admin, or themselves.
    function test_each_refused_commit_says_why() public {
        assertRefused(PUBLISHER, GHOST_APP, AppRegistry.AppNotFound.selector);
        openApp();
        assertRefused(STRANGER, APP, AppRegistry.NotInvited.selector);
        assertRefused(PUBLISHER, APP, AppRegistry.NotJoined.selector); // invited only
        join(PUBLISHER, APP, TERMS_V1, FEE);
        assertTrue(apps.canPublish(APP, PUBLISHER));

        vm.prank(APP_OWNER);
        apps.setAppTerms(APP, TERMS_V2, "");
        assertRefused(PUBLISHER, APP, AppRegistry.TermsMismatch.selector);
        vm.prank(PUBLISHER);
        apps.acceptUpdatedTerms(APP, TERMS_V2);

        // Each case below differs from a publisher who can publish in one way only, so each
        // also checks `canPublish` against `commitStateRoot` on its own.
        vm.prank(APP_OWNER);
        apps.setPublisherSuspended(APP, PUBLISHER, true);
        assertRefused(PUBLISHER, APP, AppRegistry.PublisherSuspendedApp.selector);
        vm.prank(APP_OWNER);
        apps.setPublisherSuspended(APP, PUBLISHER, false);

        vm.prank(ADMIN);
        apps.setGlobalSuspension(PUBLISHER, true);
        assertRefused(PUBLISHER, APP, AppRegistry.PublisherSuspendedGlobal.selector);
        // Banned both ways, the network-wide ban is named first; lifting it leaves the
        // app's.
        vm.prank(APP_OWNER);
        apps.setPublisherSuspended(APP, PUBLISHER, true);
        assertRefused(PUBLISHER, APP, AppRegistry.PublisherSuspendedGlobal.selector);
        vm.prank(ADMIN);
        apps.setGlobalSuspension(PUBLISHER, false);
        assertRefused(PUBLISHER, APP, AppRegistry.PublisherSuspendedApp.selector);
        vm.prank(APP_OWNER);
        apps.setPublisherSuspended(APP, PUBLISHER, false);
        assertTrue(apps.canPublish(APP, PUBLISHER));

        vm.prank(ADMIN);
        apps.setAppSuspended(APP, true);
        assertRefused(PUBLISHER, APP, AppRegistry.AppSuspended.selector);
        assertRefused(APP_OWNER, APP, AppRegistry.AppSuspended.selector);
        vm.prank(ADMIN);
        apps.setAppSuspended(APP, false);
        assertTrue(apps.canPublish(APP, PUBLISHER));
    }

    /// The DataRegistry takes commits from the AppRegistry only, so its checks cannot be
    /// skipped, even by a publisher who would pass them.
    function test_the_data_registry_cannot_be_called_directly() public {
        openApp();
        join(PUBLISHER, APP, TERMS_V1, FEE);
        vm.prank(PUBLISHER);
        vm.expectRevert(DataRegistry.Unauthorized.selector);
        data.commitStateRoot(APP, PUBLISHER, keccak256("docs"), bytes32(0), bytes32(uint256(7)));
    }

    /// The compare-and-swap is the DataRegistry's, and its refusal reaches the caller
    /// as an error in the AppRegistry's ABI.
    function test_a_stale_root_is_refused_through_the_app_registry() public {
        openApp();
        vm.prank(APP_OWNER);
        vm.expectRevert(AppRegistry.StaleStateRoot.selector);
        apps.commitStateRoot(APP, keccak256("docs"), bytes32(uint256(1)), bytes32(uint256(7)));
    }

    /// Only the admin points commits at a DataRegistry. Until one is set, nobody can
    /// commit, member or not.
    function test_commits_need_a_data_registry() public {
        vm.prank(STRANGER);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.setDataRegistry(STRANGER);

        openApp();
        vm.expectEmit(true, true, true, true, address(apps));
        emit AppRegistry.DataRegistryChanged(address(data), address(0));
        vm.prank(ADMIN);
        apps.setDataRegistry(address(0));
        assertEq(apps.dataRegistry(), address(0));
        vm.prank(APP_OWNER);
        vm.expectRevert();
        apps.commitStateRoot(APP, keccak256("docs"), bytes32(0), bytes32(uint256(7)));
    }

    // ── upgrades ──────────────────────────────────────────────────────────────

    /// The point of the proxy: a new implementation takes over the same address and
    /// the same state, and only the admin can install one.
    function test_an_upgrade_keeps_state_and_only_the_admin_can_do_it() public {
        openApp();
        join(PUBLISHER, APP, TERMS_V1, FEE);
        uint64 expiry = apps.expiresAt(uint256(APP));
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
        assertEq(apps.joinFee(APP), FEE);
        assertEq(apps.expiresAt(uint256(APP)), expiry);
        assertEq(apps.ownerOf(uint256(APP)), APP_OWNER);
        assertEq(apps.name(), "FAPP");
        assertTrue(apps.canPublish(APP, PUBLISHER));

        // Still the contract the DataRegistry takes commits from.
        vm.prank(PUBLISHER);
        apps.commitStateRoot(APP, keccak256("docs"), bytes32(0), bytes32(uint256(7)));
    }

    /// `initialize` stands in for the constructor, so it runs exactly once — and never
    /// on the bare implementation, which nobody should be able to take over.
    function test_initialize_runs_once_and_never_on_the_implementation() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        apps.initialize(STRANGER, address(usdc), 0, PERIOD);

        AppRegistry implementation = new AppRegistry();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(STRANGER, address(usdc), 0, PERIOD);
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
