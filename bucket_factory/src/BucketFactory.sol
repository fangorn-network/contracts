// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IBucket {
    function initialize(address owner, address registry) external;
}

/// Deploys per-publisher ERC-1167 minimal-proxy clones of a single Bucket
/// implementation. Each clone delegatecalls the shared implementation (a Stylus
/// contract) but keeps its own storage. Only the PublisherRegistry may create
/// buckets; it is recorded as each bucket's authorized caller.
contract BucketFactory {
    error Unauthorized();
    error CloneFailed();

    address public immutable bucketImplementation;
    address public immutable publisherRegistry;

    event BucketCreated(address indexed owner, address indexed bucket);

    constructor(address _bucketImplementation, address _publisherRegistry) {
        bucketImplementation = _bucketImplementation;
        publisherRegistry = _publisherRegistry;
    }

    function createBucket(address owner) external returns (address bucket) {
        if (msg.sender != publisherRegistry) revert Unauthorized();
        bucket = _clone(bucketImplementation);
        IBucket(bucket).initialize(owner, publisherRegistry);
        emit BucketCreated(owner, bucket);
    }

    // ponytail: inline EIP-1167 minimal proxy bytecode; avoids an OZ dep for 12 lines.
    function _clone(address impl) private returns (address instance) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, impl))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create(0, ptr, 0x37)
        }
        if (instance == address(0)) revert CloneFailed();
    }
}
