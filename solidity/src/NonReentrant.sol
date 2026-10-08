// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// A Stylus contract refuses reentrant calls unless it opts in. Solidity does the
/// opposite, so the ports mark every function that calls out — to a token, to
/// Semaphore, to a hook, or with ETH — to keep the behavior they were written
/// against.
abstract contract NonReentrant {
    error Reentrancy();

    /// 2 while a guarded function runs. Anything else means "not entered" — including
    /// zero, which is what a proxy's storage holds before the first guarded call. The
    /// flag is deliberately not initialized here: an initializer on a state variable
    /// runs in the implementation's constructor, and would never reach the proxy.
    uint256 private _entered;

    modifier nonReentrant() {
        if (_entered == 2) revert Reentrancy();
        _entered = 2;
        _;
        _entered = 1;
    }
}
