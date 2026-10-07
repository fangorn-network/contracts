// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// A Stylus contract refuses reentrant calls unless it opts in. Solidity does the
/// opposite, so the ports mark every function that calls out — to a token, to
/// Semaphore, to a hook, or with ETH — to keep the behavior they were written
/// against.
abstract contract NonReentrant {
    error Reentrancy();

    uint256 private _entered = 1;

    modifier nonReentrant() {
        if (_entered != 1) revert Reentrancy();
        _entered = 2;
        _;
        _entered = 1;
    }
}
