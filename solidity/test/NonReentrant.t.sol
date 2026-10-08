// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {NonReentrant} from "../src/NonReentrant.sol";

/// A guarded function that calls out to whoever asks, so the caller can try to re-enter.
contract Guarded is NonReentrant {
    uint256 public count;

    function poke() external nonReentrant {
        count += 1;
        (bool ok, bytes memory ret) = msg.sender.call(abi.encodeWithSignature("onPoke()"));
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}

contract NonReentrantTest is Test {
    Guarded g;
    bool reenter;

    function setUp() public {
        g = new Guarded();
    }

    function onPoke() external {
        if (reenter) g.poke();
    }

    function test_firstCall_fromZeroFlag() public {
        // Fresh storage holds 0, as a proxy's does before the first guarded call.
        g.poke();
        assertEq(g.count(), 1);
    }

    function test_flagResets_soLaterCallsPass() public {
        g.poke();
        g.poke();
        assertEq(g.count(), 2);
    }

    function test_reentryReverts() public {
        reenter = true;
        vm.expectRevert(NonReentrant.Reentrancy.selector);
        g.poke();
    }
}
