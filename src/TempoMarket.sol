// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC721 }       from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC2981 }      from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import { IERC20 }        from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 }     from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Pausable }      from "@openzeppelin/contracts/utils/Pausable.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

// ════════════════════════════════════════════════════════════════════════════
/// @title  TempoMarket
/// @notice Peer-to-peer marketplace for TimeNFT position tokens.
///
///         WHY A DEDICATED MARKET:
///         Uniswap v3 has been representing LP positions as NFTs since 2021.
///         Despite being listable on OpenSea, there is almost no trading.
///         Financial NFTs don't trade on art marketplaces because buyers
///         need to understand what they're buying, not browse aesthetics.
///
///         TempoMarket gives buyers exactly what they need:
///           - Position data (locked amount, maturity, inflation rate)
///           - Time remaining until redemption
///           - Implied yield if buying below face value
///           - Direct USDC settlement — no ETH, no slippage
///
///         MECHANICS:
///           Seller: list(tokenId, priceUsdc) → NFT escrowed in contract
///           Buyer:  buy(tokenId) → USDC transferred, NFT transferred
///                   - 1% ERC-2981 royalty auto-deducted → BurnRouter
///                   - Seller receives: price - royalty
///           Cancel: cancel(tokenId) → NFT returned to seller
///
///         SECURITY:
///           - nonReentrant on all state-changing functions
///           - NFT escrowed in contract during listing (no approval-based risk)
///           - Price in USDC only (no ETH handling — simpler, safer)
///           - Emergency pause via DAO
///           - No admin can access escrowed NFTs or USDC
// ════════════════════════════════════════════════════════════════════════════
contract TempoMarket is ReentrancyGuard, Pausable, AccessControl {
    using SafeERC20 for IERC20;

    // ── ROLES ────────────────────────────────────────────────────────────────
    bytes32 public constant DAO_ROLE     = keccak256("DAO_ROLE");
    bytes32 public constant PAUSER_ROLE  = keccak256("PAUSER_ROLE");

    // ── IMMUTABLES ───────────────────────────────────────────────────────────
    IERC721 public immutable timeNFT;   // TimeNFT contract
    IERC20  public immutable usdc;      // USDC payment token

    // ── LISTING STATE ────────────────────────────────────────────────────────
    struct Listing {
        address seller;
        uint256 priceUsdc;  // 6 decimals
        uint256 listedAt;   // timestamp
    }

    // tokenId => Listing (empty if not listed)
    mapping(uint256 => Listing) public listings;

    // ── ACCOUNTING ───────────────────────────────────────────────────────────
    uint256 public totalVolume;       // cumulative USDC traded
    uint256 public totalRoyaltyPaid;  // cumulative royalties sent to BurnRouter
    uint256 public totalSales;        // number of completed sales

    // ── EVENTS ───────────────────────────────────────────────────────────────
    event Listed(
        uint256 indexed tokenId,
        address indexed seller,
        uint256         priceUsdc,
        uint256         listedAt
    );
    event Sold(
        uint256 indexed tokenId,
        address indexed seller,
        address indexed buyer,
        uint256         priceUsdc,
        uint256         royaltyAmount,
        uint256         sellerReceived
    );
    event Canceled(
        uint256 indexed tokenId,
        address indexed seller
    );
    event PriceUpdated(
        uint256 indexed tokenId,
        uint256         oldPrice,
        uint256         newPrice
    );

    // ── ERRORS ───────────────────────────────────────────────────────────────
    error NotListed(uint256 tokenId);
    error AlreadyListed(uint256 tokenId);
    error NotSeller(uint256 tokenId, address caller);
    error ZeroPrice();
    error InsufficientAllowance(uint256 required, uint256 allowance);
    error SelfPurchase();

    // ── CONSTRUCTOR ──────────────────────────────────────────────────────────
    constructor(
        address _timeNFT,
        address _usdc,
        address _dao,
        address _guardian
    ) {
        require(_timeNFT  != address(0), "Market: zero nft");
        require(_usdc     != address(0), "Market: zero usdc");
        require(_dao      != address(0), "Market: zero dao");

        timeNFT = IERC721(_timeNFT);
        usdc    = IERC20(_usdc);

        _grantRole(DEFAULT_ADMIN_ROLE, _dao);
        _grantRole(DAO_ROLE,    _dao);
        _grantRole(PAUSER_ROLE, _guardian);
    }

    // ════════════════════════════════════════════════════════════════════════
    // SELLER FUNCTIONS
    // ════════════════════════════════════════════════════════════════════════

    /// @notice List a TimeNFT position for sale.
    ///         The NFT is transferred to this contract (escrowed) until sold or canceled.
    ///         Seller must call timeNFT.approve(address(this), tokenId) first.
    ///
    /// @param tokenId   Position NFT to list
    /// @param priceUsdc Asking price in USDC (6 decimals, e.g. 9500e6 = $9,500)
    function list(uint256 tokenId, uint256 priceUsdc)
        external
        nonReentrant
        whenNotPaused
    {
        if (priceUsdc == 0)
            revert ZeroPrice();

        if (listings[tokenId].seller != address(0))
            revert AlreadyListed(tokenId);

        // Transfer NFT into escrow
        // Will revert if caller doesn't own it or hasn't approved us
        timeNFT.transferFrom(msg.sender, address(this), tokenId);

        listings[tokenId] = Listing({
            seller:     msg.sender,
            priceUsdc:  priceUsdc,
            listedAt:   block.timestamp
        });

        emit Listed(tokenId, msg.sender, priceUsdc, block.timestamp);
    }

    /// @notice Update the price of an existing listing.
    ///         Only the original seller can update.
    function updatePrice(uint256 tokenId, uint256 newPriceUsdc)
        external
        nonReentrant
    {
        Listing storage listing = listings[tokenId];

        if (listing.seller == address(0)) revert NotListed(tokenId);
        if (listing.seller != msg.sender)  revert NotSeller(tokenId, msg.sender);
        if (newPriceUsdc == 0)             revert ZeroPrice();

        uint256 old          = listing.priceUsdc;
        listing.priceUsdc    = newPriceUsdc;

        emit PriceUpdated(tokenId, old, newPriceUsdc);
    }

    /// @notice Cancel a listing and return the NFT to the seller.
    function cancel(uint256 tokenId)
        external
        nonReentrant
    {
        Listing memory listing = listings[tokenId];

        if (listing.seller == address(0)) revert NotListed(tokenId);
        if (listing.seller != msg.sender)  revert NotSeller(tokenId, msg.sender);

        delete listings[tokenId];

        // Return NFT to seller
        timeNFT.transferFrom(address(this), msg.sender, tokenId);

        emit Canceled(tokenId, msg.sender);
    }

    // ════════════════════════════════════════════════════════════════════════
    // BUYER FUNCTIONS
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Buy a listed position.
    ///         Buyer must approve this contract to spend priceUsdc USDC.
    ///
    ///         Settlement:
    ///           1. Deduct royalty (1%) via ERC-2981
    ///           2. Transfer royalty → BurnRouter (triggers eventual burn)
    ///           3. Transfer remainder → seller
    ///           4. Transfer NFT → buyer
    ///
    /// @param tokenId Position to buy
    function buy(uint256 tokenId)
        external
        nonReentrant
        whenNotPaused
    {
        Listing memory listing = listings[tokenId];

        if (listing.seller == address(0)) revert NotListed(tokenId);
        if (listing.seller == msg.sender)  revert SelfPurchase();

        uint256 price = listing.priceUsdc;

        // Check buyer allowance upfront for clear error message
        uint256 allowance = usdc.allowance(msg.sender, address(this));
        if (allowance < price)
            revert InsufficientAllowance(price, allowance);

        // ── Compute royalty via ERC-2981 ──────────────────────────────────
        // TimeNFT implements ERC-2981 with 1% royalty to BurnRouter
        (address royaltyReceiver, uint256 royaltyAmount) =
            IERC2981(address(timeNFT)).royaltyInfo(tokenId, price);

        // Safety: royalty can never exceed 5% of sale price
        // This prevents a misconfigured royalty from bricking the market
        if (royaltyAmount > price / 20) {
            royaltyAmount = price / 20; // cap at 5%
        }

        uint256 sellerReceives = price - royaltyAmount;

        // ── Delete listing before transfers (CEI pattern) ─────────────────
        delete listings[tokenId];

        // ── Transfer USDC from buyer ──────────────────────────────────────
        usdc.safeTransferFrom(msg.sender, address(this), price);

        // ── Pay royalty to BurnRouter ─────────────────────────────────────
        if (royaltyAmount > 0 && royaltyReceiver != address(0)) {
            usdc.safeTransfer(royaltyReceiver, royaltyAmount);
            totalRoyaltyPaid += royaltyAmount;
        }

        // ── Pay seller ───────────────────────────────────────────────────
        usdc.safeTransfer(listing.seller, sellerReceives);

        // ── Transfer NFT to buyer ─────────────────────────────────────────
        timeNFT.transferFrom(address(this), msg.sender, tokenId);

        // ── Update stats ─────────────────────────────────────────────────
        totalVolume += price;
        totalSales++;

        emit Sold(
            tokenId,
            listing.seller,
            msg.sender,
            price,
            royaltyAmount,
            sellerReceives
        );
    }

    // ════════════════════════════════════════════════════════════════════════
    // VIEWS
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Get all active listings (paginated for gas efficiency)
    /// @param  offset Start index
    /// @param  limit  Max results (recommend max 100)
    function getActiveListings(uint256 offset, uint256 limit)
        external
        view
        returns (
            uint256[] memory tokenIds,
            Listing[]  memory listingData
        )
    {
        // Count active listings
        uint256 total = timeNFT.balanceOf(address(this));

        if (offset >= total) {
            return (new uint256[](0), new Listing[](0));
        }

        uint256 count = total - offset;
        if (count > limit) count = limit;

        tokenIds    = new uint256[](count);
        listingData = new Listing[](count);

        // Note: ERC721Enumerable required on TimeNFT for this to work
        // which it has (tokenOfOwnerByIndex)
        IERC721 nft = timeNFT;
        for (uint256 i = 0; i < count; i++) {
            try IERC721Enumerable(address(nft)).tokenOfOwnerByIndex(
                address(this),
                offset + i
            ) returns (uint256 tokenId) {
                tokenIds[i]    = tokenId;
                listingData[i] = listings[tokenId];
            } catch {
                break;
            }
        }
    }

    /// @notice True if a position is currently listed
    function isListed(uint256 tokenId) external view returns (bool) {
        return listings[tokenId].seller != address(0);
    }

    /// @notice Market summary stats
    function stats() external view returns (
        uint256 volume,
        uint256 royalties,
        uint256 sales,
        uint256 activeListings
    ) {
        return (
            totalVolume,
            totalRoyaltyPaid,
            totalSales,
            timeNFT.balanceOf(address(this))
        );
    }

    // ════════════════════════════════════════════════════════════════════════
    // ADMIN
    // ════════════════════════════════════════════════════════════════════════

    function pause()   external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(DAO_ROLE)    { _unpause(); }

    // ── Required for receiving NFTs ───────────────────────────────────────
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

// Minimal interface needed for enumerable check
interface IERC721Enumerable {
    function tokenOfOwnerByIndex(address owner, uint256 index)
        external
        view
        returns (uint256);
}
