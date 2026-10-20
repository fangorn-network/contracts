// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import {AppRegistry} from "../src/AppRegistry.sol";
import {DataRegistry} from "../src/DataRegistry.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC5643} from "../src/IERC5643.sol";
import {MockUSDC, Proxied} from "./Mocks.sol";

// The app a reentering token tries to claim.
bytes32 constant REENTERED = bytes32(uint256(0xEE));

/// A fee token that, whenever it is asked to move tokens, tries to claim another app.
/// It approves nothing and pays itself, so only the reentrancy guard can refuse the
/// claim. It keeps the refusal and lets the transfer succeed.
contract ReentrantToken {
    AppRegistry apps;
    bytes public refusal;

    function target(AppRegistry apps_) external {
        apps = apps_;
    }

    function clear() external {
        delete refusal;
    }

    function transferFrom(address, address, uint256) external returns (bool) {
        return _reenter();
    }

    function transfer(address, uint256) external returns (bool) {
        return _reenter();
    }

    function balanceOf(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function _reenter() private returns (bool) {
        try apps.registerApp(REENTERED, type(uint256).max) {}
        catch (bytes memory reason) {
            refusal = reason;
        }
        return true;
    }
}

/// An ERC-20 whose `transfer` and `transferFrom` return nothing, as USDT's do on
/// Ethereum mainnet. It records the last transfer and always succeeds.
contract NoReturnToken {
    address public lastFrom;
    address public lastTo;
    uint256 public lastAmount;

    function transfer(address to, uint256 amount) external {
        lastTo = to;
        lastAmount = amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        lastFrom = from;
        lastTo = to;
        lastAmount = amount;
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
    uint256 constant FEE = 0.001 ether;
    uint256 constant SUB_FEE = 2_000_000; // 2 USDC (6 decimals)
    uint64 constant PERIOD = 30 days;
    uint64 constant T0 = 1_700_000_000;

    uint8 constant STATUS_NONE = 0;
    uint8 constant STATUS_ACTIVE = 1;
    uint8 constant STATUS_SUSPENDED = 2;

    bytes32 constant DOCS = keccak256("docs");

    using stdStorage for StdStorage;

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

    /// APP claimed by APP_OWNER, with nobody else accepted yet.
    function openApp() internal {
        vm.prank(APP_OWNER);
        apps.registerApp(APP, 0);
    }

    /// `app`'s owner accepts `who`.
    function accept(bytes32 app, address who) internal {
        vm.prank(apps.getAppOwner(app));
        apps.acceptPublisher(app, who);
    }

    /// Join fees owed to `owner` from the old join flow, which nothing collects any more:
    /// written straight into storage, with the USDC to back them.
    function owe(address owner, uint256 amount) internal {
        stdstore.target(address(apps)).sig("joinFeesOwed(address)").with_key(owner).checked_write(amount);
        stdstore.target(address(apps)).sig("totalJoinFeesOwed()").checked_write(apps.totalJoinFeesOwed() + amount);
        vm.prank(STRANGER);
        usdc.transfer(address(apps), amount);
    }

    // ── apps ──────────────────────────────────────────────────────────────────

    function test_an_app_id_is_claimed_once() public {
        openApp();
        assertEq(apps.getAppOwner(APP), APP_OWNER);
        vm.prank(STRANGER);
        vm.expectRevert(AppRegistry.AppAlreadyRegistered.selector);
        apps.registerApp(APP, 0);
        assertEq(apps.getAppOwner(APP), APP_OWNER);
    }

    function test_an_unclaimed_app_cannot_be_configured() public {
        vm.startPrank(APP_OWNER);
        vm.expectRevert(AppRegistry.AppNotFound.selector);
        apps.acceptPublisher(GHOST_APP, PUBLISHER);
        vm.expectRevert(AppRegistry.AppNotFound.selector);
        apps.setAppAgentUri(GHOST_APP, "https://x.example/card.json");
        vm.stopPrank();
    }

    function test_an_app_owner_is_their_own_first_publisher() public {
        vm.expectEmit(true, true, true, true, address(apps));
        emit AppRegistry.PublisherAccepted(APP, APP_OWNER);
        openApp();
        assertTrue(apps.canPublish(APP, APP_OWNER));
        // Claiming an app must not enrol you anywhere else.
        assertFalse(apps.canPublish(OTHER_APP, APP_OWNER));
    }

    function test_moving_the_agent_card_leaves_publishers_alone() public {
        openApp();
        accept(APP, PUBLISHER);

        vm.prank(STRANGER);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.setAppAgentUri(APP, "https://evil.example/card.json");

        vm.startPrank(APP_OWNER);
        apps.setAppAgentUri(APP, "https://a.example/card.json");
        apps.setAppAgentUri(APP, "https://b.example/card.json");
        vm.stopPrank();
        assertEq(apps.appAgentUri(APP), "https://b.example/card.json");
        assertTrue(apps.canPublish(APP, PUBLISHER));
        assertEq(apps.appAgentUri(OTHER_APP), "");
    }

    function test_the_admin_can_take_down_a_whole_app() public {
        openApp();
        vm.prank(APP_OWNER);
        apps.registerApp(OTHER_APP, 0);
        accept(APP, PUBLISHER);

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
        assertEq(uint8(apps.statusForApp(APP, PUBLISHER)), STATUS_ACTIVE);

        // Reinstating restores the publishers exactly as they were.
        vm.prank(ADMIN);
        apps.setAppSuspended(APP, false);
        assertTrue(apps.canPublish(APP, PUBLISHER));
        assertTrue(apps.canPublish(APP, APP_OWNER));
    }

    // ── accepting publishers ──────────────────────────────────────────────────

    /// The owner's acceptance is the whole membership: no invitation, no terms, no fee.
    function test_the_owner_accepts_a_publisher_and_nobody_else_can() public {
        openApp();
        assertFalse(apps.canPublish(APP, PUBLISHER));

        vm.prank(STRANGER);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.acceptPublisher(APP, STRANGER);
        vm.prank(PUBLISHER);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.acceptPublisher(APP, PUBLISHER);
        // Not even the protocol admin: who an app sponsors is its owner's call.
        vm.prank(ADMIN);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.acceptPublisher(APP, PUBLISHER);

        vm.expectEmit(true, true, true, true, address(apps));
        emit AppRegistry.PublisherAccepted(APP, PUBLISHER);
        accept(APP, PUBLISHER);
        assertEq(uint8(apps.statusForApp(APP, PUBLISHER)), STATUS_ACTIVE);
        assertTrue(apps.canPublish(APP, PUBLISHER));
        assertEq(usdc.calls(), 0, "accepting a publisher moved tokens");

        // Once: a member, or a suspended one, is not accepted again.
        vm.startPrank(APP_OWNER);
        vm.expectRevert(AppRegistry.AlreadyAccepted.selector);
        apps.acceptPublisher(APP, PUBLISHER);
        vm.expectRevert(AppRegistry.AlreadyAccepted.selector);
        apps.acceptPublisher(APP, APP_OWNER);
        apps.setPublisherSuspended(APP, PUBLISHER, true);
        vm.expectRevert(AppRegistry.AlreadyAccepted.selector);
        apps.acceptPublisher(APP, PUBLISHER);
        vm.stopPrank();
    }

    /// An invitation left over from the old join flow is not a membership, and the
    /// owner accepts that wallet like any other.
    function test_a_leftover_invitation_is_accepted_like_none() public {
        openApp();
        stdstore.target(address(apps)).sig("statusForApp(bytes32,address)").with_key(APP).with_key(PUBLISHER)
            .checked_write(uint256(3));
        assertFalse(apps.canPublish(APP, PUBLISHER));
        vm.prank(APP_OWNER);
        vm.expectRevert(AppRegistry.NotAccepted.selector);
        apps.setPublisherSuspended(APP, PUBLISHER, true);
        accept(APP, PUBLISHER);
        assertTrue(apps.canPublish(APP, PUBLISHER));
    }

    function test_membership_is_per_app() public {
        openApp();
        vm.prank(APP_OWNER);
        apps.registerApp(OTHER_APP, 0);
        accept(APP, PUBLISHER);

        assertTrue(apps.canPublish(APP, PUBLISHER));
        assertFalse(apps.canPublish(OTHER_APP, PUBLISHER));
        assertFalse(apps.canPublish(APP, STRANGER));
    }

    function test_an_app_owner_can_eject_a_publisher_from_their_app_only() public {
        openApp();
        vm.prank(APP_OWNER);
        apps.registerApp(OTHER_APP, 0);
        accept(APP, PUBLISHER);
        accept(OTHER_APP, PUBLISHER);

        vm.prank(STRANGER);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.setPublisherSuspended(APP, PUBLISHER, true);

        vm.expectEmit(true, true, true, true, address(apps));
        emit AppRegistry.PublisherSuspensionChanged(APP, PUBLISHER, true);
        vm.prank(APP_OWNER);
        apps.setPublisherSuspended(APP, PUBLISHER, true);
        assertEq(uint8(apps.statusForApp(APP, PUBLISHER)), STATUS_SUSPENDED);
        assertFalse(apps.canPublish(APP, PUBLISHER));
        assertTrue(apps.canPublish(OTHER_APP, PUBLISHER), "one app's ban leaked into another");

        vm.startPrank(APP_OWNER);
        // Only a publisher the app accepted can be suspended, and only someone
        // suspended reinstated.
        vm.expectRevert(AppRegistry.NotAccepted.selector);
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

    // ── join fees from the old flow ───────────────────────────────────────────

    /// Nothing collects join fees any more, but what an owner was owed stays theirs:
    /// only they take it out, all of it, once, and a refused payout leaves it owed.
    function test_join_fees_still_owed_go_to_their_owner() public {
        owe(APP_OWNER, 3 * FEE);

        vm.prank(STRANGER);
        vm.expectRevert(AppRegistry.NothingToWithdraw.selector);
        apps.withdrawJoinFees(STRANGER);

        usdc.setMode(MockUSDC.Mode.ReturnFalse);
        vm.prank(APP_OWNER);
        vm.expectRevert(AppRegistry.TransferFailed.selector);
        apps.withdrawJoinFees(APP_OWNER);
        assertEq(apps.joinFeesOwed(APP_OWNER), 3 * FEE);
        assertEq(apps.totalJoinFeesOwed(), 3 * FEE);
        usdc.setMode(MockUSDC.Mode.Ok);

        vm.expectEmit(true, true, true, true, address(apps));
        emit AppRegistry.JoinFeesWithdrawn(APP_OWNER, STRANGER, 3 * FEE);
        vm.prank(APP_OWNER);
        apps.withdrawJoinFees(STRANGER);
        assertEq(usdc.lastTo(), STRANGER);
        assertEq(usdc.lastAmount(), 3 * FEE);
        assertEq(apps.joinFeesOwed(APP_OWNER), 0);
        assertEq(apps.totalJoinFeesOwed(), 0);
        assertEq(usdc.balanceOf(address(apps)), 0);
        vm.prank(APP_OWNER);
        vm.expectRevert(AppRegistry.NothingToWithdraw.selector);
        apps.withdrawJoinFees(APP_OWNER);
    }

    /// Moving the fee token hands control to the token, during a claim, a renewal and a
    /// payout. A guarded function called from there is refused, even one the caller
    /// could otherwise use: here, the token claiming an app.
    function test_a_fee_transfer_cannot_reenter() public {
        ReentrantToken token = new ReentrantToken();
        apps = Proxied.appRegistry(ADMIN, address(token), SUB_FEE, PERIOD);
        token.target(apps);
        bytes memory guarded = abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);

        vm.warp(T0);
        vm.prank(APP_OWNER);
        apps.registerApp(APP, SUB_FEE);
        assertEq(token.refusal(), guarded);
        assertEq(apps.getAppOwner(APP), APP_OWNER, "the claim itself went through");

        vm.warp(T0 + 1);
        token.clear();
        vm.prank(APP_OWNER);
        apps.renewSubscription(uint256(APP), PERIOD);
        assertEq(token.refusal(), guarded);

        token.clear();
        stdstore.target(address(apps)).sig("joinFeesOwed(address)").with_key(APP_OWNER).checked_write(FEE);
        stdstore.target(address(apps)).sig("totalJoinFeesOwed()").checked_write(FEE);
        vm.prank(APP_OWNER);
        apps.withdrawJoinFees(APP_OWNER);
        assertEq(token.refusal(), guarded);
        assertEq(apps.getAppOwner(REENTERED), address(0));
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
            apps.registerApp(OTHER_APP, SUB_FEE);
            assertEq(apps.getAppOwner(OTHER_APP), address(0), "an unpaid claim left an app behind");
            assertEq(apps.balanceOf(STRANGER), 0, "an unpaid claim minted a token");
        }
        usdc.setMode(MockUSDC.Mode.Ok);

        vm.warp(T0);
        vm.expectEmit(true, true, true, true, address(apps));
        emit IERC5643.SubscriptionUpdate(uint256(APP), T0 + PERIOD);
        vm.prank(APP_OWNER);
        apps.registerApp(APP, SUB_FEE);
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
        apps.registerApp(OTHER_APP, SUB_FEE - 1);
        vm.prank(STRANGER);
        apps.registerApp(OTHER_APP, SUB_FEE * 10);
        assertEq(usdc.lastAmount(), SUB_FEE);
    }

    function test_a_free_subscription_never_touches_the_token() public {
        // Fee is zero and the token would revert: the claim must not call it.
        usdc.setMode(MockUSDC.Mode.Revert);
        vm.prank(APP_OWNER);
        apps.registerApp(APP, 0);
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
        assertEq(apps.name(), "FANGAPP");
        assertEq(apps.symbol(), "FANGAPP");

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
        apps.registerApp(OTHER_APP, 0);
        assertEq(apps.expiresAt(uint256(OTHER_APP)), block.timestamp + week);
    }

    function test_the_period_cannot_start_at_zero() public {
        address implementation = address(new AppRegistry());
        bytes memory init = abi.encodeCall(AppRegistry.initialize, (ADMIN, address(usdc), 0, 0));
        vm.expectRevert(AppRegistry.ZeroPeriod.selector);
        new ERC1967Proxy(implementation, init);
    }

    /// The admin sweeps the protocol's USDC (subscription fees) and any other token sent
    /// here by mistake, but never the join fees still owed to app owners.
    function test_only_the_admin_sweeps_tokens() public {
        vm.prank(ADMIN);
        apps.setSubscriptionFee(SUB_FEE);
        vm.prank(APP_OWNER);
        apps.registerApp(APP, SUB_FEE);
        owe(APP_OWNER, FEE);
        assertEq(usdc.balanceOf(address(apps)), SUB_FEE + FEE);

        vm.prank(APP_OWNER);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.withdrawToken(address(usdc), STRANGER, SUB_FEE);

        // One base unit more than the protocol's share would reach into the owner's.
        vm.prank(ADMIN);
        vm.expectRevert(AppRegistry.ExceedsProtocolBalance.selector);
        apps.withdrawToken(address(usdc), STRANGER, SUB_FEE + 1);

        // A transfer the token refuses changes nothing.
        usdc.setMode(MockUSDC.Mode.ReturnFalse);
        vm.prank(ADMIN);
        vm.expectRevert(AppRegistry.TransferFailed.selector);
        apps.withdrawToken(address(usdc), STRANGER, SUB_FEE);
        usdc.setMode(MockUSDC.Mode.Ok);

        vm.expectEmit(true, true, true, true, address(apps));
        emit AppRegistry.TokenWithdrawn(address(usdc), STRANGER, SUB_FEE);
        vm.prank(ADMIN);
        apps.withdrawToken(address(usdc), STRANGER, SUB_FEE);
        assertEq(usdc.lastTo(), STRANGER);
        assertEq(usdc.balanceOf(address(apps)), FEE, "the owner's join fee is still there");

        // The owner's fee is still theirs to take.
        vm.prank(APP_OWNER);
        apps.withdrawJoinFees(APP_OWNER);
        assertEq(usdc.balanceOf(address(apps)), 0);

        // Another token is not held for anyone, so any amount can go.
        MockUSDC stray = new MockUSDC();
        vm.prank(ADMIN);
        apps.withdrawToken(address(stray), STRANGER, 5);
        assertEq(stray.lastTo(), STRANGER);
        assertEq(stray.lastAmount(), 5);
    }

    /// Tokens that return nothing from `transfer` work, both as the fee token and when
    /// swept; an address with no code is not a token.
    function test_tokens_that_return_nothing_are_supported() public {
        NoReturnToken token = new NoReturnToken();
        AppRegistry registry = Proxied.appRegistry(ADMIN, address(token), SUB_FEE, PERIOD);
        vm.prank(APP_OWNER);
        registry.registerApp(APP, SUB_FEE);
        assertEq(token.lastFrom(), APP_OWNER);
        assertEq(token.lastAmount(), SUB_FEE);

        vm.prank(ADMIN);
        apps.withdrawToken(address(token), STRANGER, 5);
        assertEq(token.lastTo(), STRANGER);
        assertEq(token.lastAmount(), 5);

        vm.prank(ADMIN);
        vm.expectRevert(AppRegistry.TransferFailed.selector);
        apps.withdrawToken(makeAddr("no-code"), STRANGER, 5);
    }

    // ── network-wide bans ─────────────────────────────────────────────────────

    /// A wallet that has never been seen can claim an app and be accepted into one:
    /// there is no registration step in front of either.
    function test_claiming_and_adding_need_no_registration() public {
        address newcomer = makeAddr("newcomer");

        vm.prank(newcomer);
        apps.registerApp(OTHER_APP, 0);
        assertEq(apps.getAppOwner(OTHER_APP), newcomer);

        openApp();
        accept(APP, newcomer);
        assertTrue(apps.canPublish(APP, newcomer));
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

    /// A banned owner's app keeps running, but the owner cannot bring anyone in (which
    /// would let them keep publishing through new wallets) or change what the app
    /// points to. Lifting the ban gives all of it back.
    function test_a_banned_owner_cannot_accept_or_repoint_their_app() public {
        openApp();
        accept(APP, PUBLISHER);
        vm.prank(ADMIN);
        apps.setGlobalSuspension(APP_OWNER, true);

        vm.startPrank(APP_OWNER);
        vm.expectRevert(AppRegistry.PublisherSuspendedGlobal.selector);
        apps.acceptPublisher(APP, makeAddr("sock-puppet"));
        vm.expectRevert(AppRegistry.PublisherSuspendedGlobal.selector);
        apps.setAppAgentUri(APP, "https://elsewhere.example/card");
        vm.stopPrank();
        assertEq(uint8(apps.statusForApp(APP, makeAddr("sock-puppet"))), STATUS_NONE);
        assertEq(apps.appAgentUri(APP), "");

        // The app itself keeps running for its other publishers.
        assertTrue(apps.canPublish(APP, PUBLISHER));

        vm.prank(ADMIN);
        apps.setGlobalSuspension(APP_OWNER, false);
        vm.startPrank(APP_OWNER);
        apps.acceptPublisher(APP, makeAddr("sock-puppet"));
        apps.setAppAgentUri(APP, "ipfs://card");
        vm.stopPrank();
    }

    /// The reason the check exists: a wallet the protocol admin banned network-wide
    /// cannot come back as an app owner, or be accepted into an app by one.
    function test_a_globally_banned_wallet_can_neither_claim_nor_be_added() public {
        vm.prank(ADMIN);
        apps.setGlobalSuspension(STRANGER, true);

        vm.prank(STRANGER);
        vm.expectRevert(AppRegistry.PublisherSuspendedGlobal.selector);
        apps.registerApp(OTHER_APP, 0);
        assertEq(apps.getAppOwner(OTHER_APP), address(0));

        openApp();
        vm.prank(APP_OWNER);
        vm.expectRevert(AppRegistry.PublisherSuspendedGlobal.selector);
        apps.acceptPublisher(APP, STRANGER);
        assertEq(uint8(apps.statusForApp(APP, STRANGER)), STATUS_NONE);

        vm.prank(ADMIN);
        apps.setGlobalSuspension(STRANGER, false);
        accept(APP, STRANGER);
        vm.prank(STRANGER);
        apps.registerApp(OTHER_APP, 0);
    }

    // ── presenting ────────────────────────────────────────────────────────────

    /// An exclusion alternates exclude and restore, counts every change, and is the
    /// owner's alone. A publisher, a repo and a key are different exclusions.
    function test_exclusions_alternate_and_count_each_change() public {
        openApp();
        bytes32 repo = apps.exclusionId(PUBLISHER, DOCS, bytes32(0));

        vm.prank(STRANGER);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.exclude(APP, PUBLISHER, DOCS, bytes32(0));

        vm.startPrank(APP_OWNER);
        vm.expectRevert(AppRegistry.NotExcluded.selector);
        apps.restore(APP, PUBLISHER, DOCS, bytes32(0));
        vm.expectEmit(true, true, true, true, address(apps));
        emit AppRegistry.ExclusionChanged(APP, PUBLISHER, repo, DOCS, bytes32(0), 1);
        apps.exclude(APP, PUBLISHER, DOCS, bytes32(0));
        vm.expectRevert(AppRegistry.AlreadyExcluded.selector);
        apps.exclude(APP, PUBLISHER, DOCS, bytes32(0));
        apps.restore(APP, PUBLISHER, DOCS, bytes32(0));
        vm.stopPrank();

        assertEq(apps.exclusionCount(APP, repo), 2);
        assertEq(apps.exclusionCount(APP, apps.exclusionId(PUBLISHER, bytes32(0), bytes32(0))), 0);
        assertEq(apps.exclusionCount(OTHER_APP, repo), 0);
    }

    /// `who` may not publish in `app`: it presents nothing of `who`, and the upload gate
    /// sponsors none of its bytes.
    function assertRefused(address who, bytes32 app) internal view {
        assertFalse(apps.canPublish(app, who));
        (bool allowed,,) = apps.access(app, who);
        assertFalse(allowed);
    }

    /// Every way a publisher drops out of an app, and back. Each case differs from a
    /// publisher who can publish in one way only.
    function test_each_way_out_of_an_app() public {
        assertRefused(PUBLISHER, GHOST_APP);
        openApp();
        assertRefused(PUBLISHER, APP); // not accepted yet
        accept(APP, PUBLISHER);
        assertTrue(apps.canPublish(APP, PUBLISHER));

        vm.prank(APP_OWNER);
        apps.setPublisherSuspended(APP, PUBLISHER, true);
        assertRefused(PUBLISHER, APP);
        vm.prank(APP_OWNER);
        apps.setPublisherSuspended(APP, PUBLISHER, false);

        vm.prank(ADMIN);
        apps.setGlobalSuspension(PUBLISHER, true);
        assertRefused(PUBLISHER, APP);
        // Banned both ways, lifting the network-wide ban leaves the app's.
        vm.prank(APP_OWNER);
        apps.setPublisherSuspended(APP, PUBLISHER, true);
        assertRefused(PUBLISHER, APP);
        vm.prank(ADMIN);
        apps.setGlobalSuspension(PUBLISHER, false);
        assertRefused(PUBLISHER, APP);
        vm.prank(APP_OWNER);
        apps.setPublisherSuspended(APP, PUBLISHER, false);
        assertTrue(apps.canPublish(APP, PUBLISHER));

        vm.prank(ADMIN);
        apps.setAppSuspended(APP, true);
        assertRefused(PUBLISHER, APP);
        assertRefused(APP_OWNER, APP);
        vm.prank(ADMIN);
        apps.setAppSuspended(APP, false);
        assertTrue(apps.canPublish(APP, PUBLISHER));

        // An expired subscription, and a cancelled one, stop everyone until renewed.
        vm.warp(apps.expiresAt(uint256(APP)));
        assertRefused(PUBLISHER, APP);
        assertRefused(APP_OWNER, APP);
        vm.prank(APP_OWNER);
        apps.renewSubscription(uint256(APP), PERIOD);
        assertTrue(apps.canPublish(APP, PUBLISHER));
        vm.prank(APP_OWNER);
        apps.cancelSubscription(uint256(APP));
        assertRefused(PUBLISHER, APP);
        vm.prank(APP_OWNER);
        apps.renewSubscription(uint256(APP), PERIOD);
        assertTrue(apps.canPublish(APP, PUBLISHER));
    }

    /// A lapsed app sponsors and includes nothing. Managing its publishers stays open,
    /// and renewing restores everything.
    function test_an_expired_app_sponsors_nothing_until_renewed() public {
        openApp();
        accept(APP, PUBLISHER);
        vm.warp(apps.expiresAt(uint256(APP)));

        // The gate sees it in its one read.
        (bool allowed,, uint64 expiry) = apps.access(APP, PUBLISHER);
        assertFalse(allowed);
        assertEq(expiry, block.timestamp);

        // Still open: accepting and suspending publishers.
        accept(APP, STRANGER);
        vm.prank(APP_OWNER);
        apps.setPublisherSuspended(APP, STRANGER, true);
        assertFalse(apps.canPublish(APP, STRANGER));

        // Renewing lifts it at once.
        vm.prank(APP_OWNER);
        apps.renewSubscription(uint256(APP), PERIOD);
        assertTrue(apps.canPublish(APP, PUBLISHER));
    }

    /// Only the admin repoints the DataRegistry address.
    function test_only_the_admin_repoints_the_data_registry() public {
        vm.prank(STRANGER);
        vm.expectRevert(AppRegistry.Unauthorized.selector);
        apps.setDataRegistry(STRANGER);

        vm.expectEmit(true, true, true, true, address(apps));
        emit AppRegistry.DataRegistryChanged(address(data), address(0));
        vm.prank(ADMIN);
        apps.setDataRegistry(address(0));
        assertEq(apps.dataRegistry(), address(0));
    }

    // ── upgrades ──────────────────────────────────────────────────────────────

    /// The point of the proxy: a new implementation takes over the same address and
    /// the same state, and only the admin can install one.
    function test_an_upgrade_keeps_state_and_only_the_admin_can_do_it() public {
        openApp();
        accept(APP, PUBLISHER);
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
        assertEq(apps.expiresAt(uint256(APP)), expiry);
        assertEq(apps.ownerOf(uint256(APP)), APP_OWNER);
        assertEq(apps.name(), "FANGAPP");
        assertTrue(apps.canPublish(APP, PUBLISHER));
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
