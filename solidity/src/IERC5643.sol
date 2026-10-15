// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// ERC-5643: subscription NFTs. An extension of ERC-721; interface id 0x8c65f84d.
/// https://eips.ethereum.org/EIPS/eip-5643
interface IERC5643 {
    /// Emitted whenever a subscription's expiration changes; 0 when it is cancelled.
    event SubscriptionUpdate(uint256 indexed tokenId, uint64 expiration);

    /// Renews the subscription of `tokenId` by `duration` seconds. Reverts if `tokenId`
    /// is not a valid NFT.
    function renewSubscription(uint256 tokenId, uint64 duration) external payable;

    /// Cancels the subscription of `tokenId`. Reverts if `tokenId` is not a valid NFT.
    function cancelSubscription(uint256 tokenId) external payable;

    /// When the subscription of `tokenId` expires. Reverts if `tokenId` is not a valid
    /// NFT.
    function expiresAt(uint256 tokenId) external view returns (uint64);

    /// Whether the subscription of `tokenId` can be renewed. Reverts if `tokenId` is not
    /// a valid NFT.
    function isRenewable(uint256 tokenId) external view returns (bool);
}
