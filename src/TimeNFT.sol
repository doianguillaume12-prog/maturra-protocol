// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC721 }           from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { ERC721Enumerable } from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import { ERC2981 }          from "@openzeppelin/contracts/token/common/ERC2981.sol";
import { AccessControl }    from "@openzeppelin/contracts/access/AccessControl.sol";
import { Strings }          from "@openzeppelin/contracts/utils/Strings.sol";
import { Base64 }           from "@openzeppelin/contracts/utils/Base64.sol";

// ════════════════════════════════════════════════════════════════════════════
/// @title  TimeNFT
/// @notice ERC-721 position token for MATURRA Protocol.
///         Each token represents one locked capital position with:
///           - lockedAmount  : USDC deposited (6 decimals)
///           - lockDuration  : seconds of lock
///           - inflationBps  : weighted inflation rate at mint (basis points)
///           - timeValue     : real maturraral value captured (18 decimals)
///           - maturesAt     : unix timestamp when principal can be redeemed
///
/// @dev    Key design decisions:
///
///         1. METADATA ON-CHAIN — SVG and JSON generated fully on-chain.
///            No IPFS dependency. Positions are readable even if our frontend
///            goes offline. This is critical for financial instruments.
///
///         2. ERC-2981 ROYALTIES — 1% royalty on every secondary transfer,
///            routed to the BurnRouter which swaps to $MATURRA and burns.
///            This is the "Flux B" burn engine (secondary market burns).
///
///         3. SOUL-BOUND UNTIL TRANSFER — NFT is transferable (so it can be
///            sold on MaturraMarket), but redemption requires being the owner
///            at maturity. Buying someone's NFT = buying their locked position.
///
///         4. MINT/BURN ONLY BY VAULT — prevents any external actor from
///            creating fake positions or burning positions they don't own.
///
///         5. NO APPROVAL TO ZERO ADDRESS — prevents accidental burns via
///            transferFrom to address(0). Use vault.redeem() instead.
// ════════════════════════════════════════════════════════════════════════════
contract TimeNFT is ERC721, ERC721Enumerable, ERC2981, AccessControl {
    using Strings for uint256;

    // ── ROLES ────────────────────────────────────────────────────────────────
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");

    // ── ROYALTY ──────────────────────────────────────────────────────────────
    uint96 public constant ROYALTY_BPS = 100; // 1% on secondary sales

    // ── POSITION DATA ────────────────────────────────────────────────────────
    struct Position {
        uint128 lockedAmount;    // USDC (6 decimals) — max 340T USDC, safe
        uint128 timeValue;       // $TIME equivalent value (18 dec, truncated)
        uint64  lockDuration;    // seconds
        uint64  maturesAt;       // unix timestamp
        uint32  inflationBps;    // basis points, max 655% — safe for uint32
        uint32  mintedAt;        // unix timestamp (uint32 valid until year 2106)
        bool    redeemed;        // true after vault.redeem()
    }

    // tokenId => Position
    mapping(uint256 => Position) public positions;

    // ── COUNTERS ─────────────────────────────────────────────────────────────
    uint256 private _nextTokenId = 1;
    uint256 public  totalMinted;
    uint256 public  totalRedeemed;

    // ── EVENTS ───────────────────────────────────────────────────────────────
    event PositionMinted(
        uint256 indexed tokenId,
        address indexed to,
        uint128 lockedAmount,
        uint64  lockDuration,
        uint32  inflationBps,
        uint128 timeValue,
        uint64  maturesAt
    );
    event PositionRedeemed(
        uint256 indexed tokenId,
        address indexed by
    );

    // ── ERRORS ───────────────────────────────────────────────────────────────
    error OnlyVault();
    error AlreadyRedeemed(uint256 tokenId);
    error NotMatured(uint256 tokenId, uint256 maturesAt, uint256 currentTime);
    error TransferToZero();
    error ZeroAmount();

    // ── CONSTRUCTOR ──────────────────────────────────────────────────────────
    constructor(address _vault, address _burnRouter)
        ERC721("MATURRA Time Position", "tTIME")
    {
        require(_vault      != address(0), "TimeNFT: zero vault");
        require(_burnRouter != address(0), "TimeNFT: zero burnRouter");

        _grantRole(DEFAULT_ADMIN_ROLE, _vault);
        _grantRole(VAULT_ROLE, _vault);

        // Set royalty receiver to BurnRouter — all secondary royalties auto-burn
        _setDefaultRoyalty(_burnRouter, ROYALTY_BPS);
    }

    // ════════════════════════════════════════════════════════════════════════
    // VAULT-ONLY FUNCTIONS
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Mint a new position NFT. Only callable by MaturraVault.
    /// @param  to            Recipient of the NFT
    /// @param  lockedAmount  USDC deposited (6 decimals)
    /// @param  lockDuration  Lock period in seconds
    /// @param  inflationBps  Weighted inflation rate at mint
    /// @param  timeValue     Computed real maturraral value (18 decimals, truncated to 128)
    /// @return tokenId       The minted token ID
    function mint(
        address to,
        uint128 lockedAmount,
        uint64  lockDuration,
        uint32  inflationBps,
        uint128 timeValue
    )
        external
        onlyRole(VAULT_ROLE)
        returns (uint256 tokenId)
    {
        if (lockedAmount == 0) revert ZeroAmount();

        tokenId = _nextTokenId++;

        uint64 maturesAt = uint64(block.timestamp) + lockDuration;

        positions[tokenId] = Position({
            lockedAmount: lockedAmount,
            timeValue:    timeValue,
            lockDuration: lockDuration,
            maturesAt:    maturesAt,
            inflationBps: inflationBps,
            mintedAt:     uint32(block.timestamp),
            redeemed:     false
        });

        totalMinted++;

        _safeMint(to, tokenId);

        emit PositionMinted(
            tokenId, to, lockedAmount,
            lockDuration, inflationBps, timeValue, maturesAt
        );
    }

    /// @notice Mark position as redeemed and burn the NFT.
    ///         Only callable by MaturraVault after maturity check.
    /// @param  tokenId   The position to redeem
    /// @param  owner     Must match ownerOf(tokenId) — vault passes this for safety
    function redeem(uint256 tokenId, address owner)
        external
        onlyRole(VAULT_ROLE)
    {
        if (positions[tokenId].redeemed)
            revert AlreadyRedeemed(tokenId);

        if (block.timestamp < positions[tokenId].maturesAt)
            revert NotMatured(
                tokenId,
                positions[tokenId].maturesAt,
                block.timestamp
            );

        require(ownerOf(tokenId) == owner, "TimeNFT: not owner");

        positions[tokenId].redeemed = true;
        totalRedeemed++;

        _burn(tokenId);

        emit PositionRedeemed(tokenId, owner);
    }

    // ════════════════════════════════════════════════════════════════════════
    // ON-CHAIN METADATA — SVG + JSON, fully on-chain
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Returns base64-encoded JSON metadata with SVG image, fully on-chain.
    function tokenURI(uint256 tokenId)
        public
        view
        override
        returns (string memory)
    {
        _requireOwned(tokenId);

        Position memory pos = positions[tokenId];

        string memory svg   = _buildSVG(tokenId, pos);
        string memory json  = _buildJSON(tokenId, pos, svg);

        return string(
            abi.encodePacked(
                "data:application/json;base64,",
                Base64.encode(bytes(json))
            )
        );
    }

    /// @dev Build the SVG image — dark card with position data
    function _buildSVG(uint256 tokenId, Position memory pos)
        internal
        view
        returns (string memory)
    {
        // Time remaining calculation (as days)
        string memory statusStr;
        string memory statusColor;

        if (pos.redeemed) {
            statusStr   = "REDEEMED";
            statusColor = "#8E8E93";
        } else if (uint64(block.timestamp) >= pos.maturesAt) {
            statusStr   = "READY TO REDEEM";
            statusColor = "#30D158";
        } else {
            uint256 daysLeft = (pos.maturesAt - uint64(block.timestamp)) / 1 days;
            statusStr   = string(abi.encodePacked(daysLeft.toString(), " DAYS LEFT"));
            statusColor = "#0A84FF";
        }

        // Format locked amount: USDC has 6 decimals
        string memory usdcStr = _formatUSDC(pos.lockedAmount);

        // Format inflation rate: basis points -> percentage string
        string memory inflStr = _formatBps(pos.inflationBps);

        // Format time value (18 dec -> human readable)
        string memory tvStr  = _formatTimeValue(pos.timeValue);

        return string(abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" width="400" height="400" viewBox="0 0 400 400">',
            '<defs>',
            '<linearGradient id="bg" x1="0%" y1="0%" x2="100%" y2="100%">',
            '<stop offset="0%" style="stop-color:#0A0A0A"/>',
            '<stop offset="100%" style="stop-color:#1C1C1E"/>',
            '</linearGradient>',
            '<linearGradient id="glow" x1="0%" y1="0%" x2="100%" y2="0%">',
            '<stop offset="0%" style="stop-color:#00B86B;stop-opacity:0"/>',
            '<stop offset="50%" style="stop-color:#00B86B;stop-opacity:0.6"/>',
            '<stop offset="100%" style="stop-color:#00B86B;stop-opacity:0"/>',
            '</linearGradient>',
            '</defs>',
            // Background
            '<rect width="400" height="400" fill="url(#bg)" rx="16"/>',
            // Top accent line
            '<rect x="0" y="0" width="400" height="2" fill="url(#glow)" rx="1"/>',
            // Logo
            '<text x="24" y="44" font-family="monospace" font-size="20" font-weight="bold" fill="#00B86B">MATURRA</text>',
            '<text x="100" y="44" font-family="monospace" font-size="11" fill="#3A3A3C" letter-spacing="2">PROTOCOL</text>',
            // Token ID
            '<text x="376" y="44" font-family="monospace" font-size="11" fill="#3A3A3C" text-anchor="end">#',
            tokenId.toString(),
            '</text>',
            // Divider
            '<line x1="24" y1="60" x2="376" y2="60" stroke="#2A2A2A" stroke-width="0.5"/>',
            // Locked Amount
            '<text x="24" y="104" font-family="monospace" font-size="10" fill="#8E8E93" letter-spacing="1">LOCKED</text>',
            '<text x="24" y="128" font-family="Arial,sans-serif" font-size="32" font-weight="bold" fill="#F5F5F7">$',
            usdcStr,
            '</text>',
            '<text x="24" y="148" font-family="monospace" font-size="10" fill="#3A3A3C">USDC</text>',
            // Time Value
            '<text x="24" y="192" font-family="monospace" font-size="10" fill="#8E8E93" letter-spacing="1">MATURRARAL VALUE</text>',
            '<text x="24" y="214" font-family="Arial,sans-serif" font-size="22" font-weight="bold" fill="#00B86B">',
            tvStr,
            ' TIME</text>',
            // Stats row
            '<rect x="24" y="240" width="168" height="56" rx="8" fill="#1C1C1E" stroke="#2A2A2A" stroke-width="0.5"/>',
            '<text x="36" y="260" font-family="monospace" font-size="9" fill="#8E8E93">INFLATION RATE</text>',
            '<text x="36" y="280" font-family="Arial,sans-serif" font-size="16" font-weight="bold" fill="#F5F5F7">',
            inflStr,
            '%</text>',
            '<rect x="208" y="240" width="168" height="56" rx="8" fill="#1C1C1E" stroke="#2A2A2A" stroke-width="0.5"/>',
            '<text x="220" y="260" font-family="monospace" font-size="9" fill="#8E8E93">LOCK DURATION</text>',
            '<text x="220" y="280" font-family="Arial,sans-serif" font-size="16" font-weight="bold" fill="#F5F5F7">',
            (uint256(pos.lockDuration) / 1 days).toString(),
            ' DAYS</text>',
            // Status badge
            '<rect x="24" y="316" width="352" height="44" rx="8" fill="#0A0A0A" stroke="#2A2A2A" stroke-width="0.5"/>',
            '<circle cx="44" cy="338" r="5" fill="',
            statusColor,
            '"/>',
            '<text x="58" y="343" font-family="monospace" font-size="11" font-weight="bold" fill="',
            statusColor,
            '">',
            statusStr,
            '</text>',
            // Bottom
            '<text x="24" y="390" font-family="monospace" font-size="9" fill="#3A3A3C">maturra.finance</text>',
            '<text x="376" y="390" font-family="monospace" font-size="9" fill="#3A3A3C" text-anchor="end">',
            'MATURES ',
            _formatTimestamp(pos.maturesAt),
            '</text>',
            '</svg>'
        ));
    }

    /// @dev Build JSON metadata with attributes for marketplaces
    function _buildJSON(
        uint256 tokenId,
        Position memory pos,
        string memory svg
    ) internal view returns (string memory) {
        string memory imageData = string(
            abi.encodePacked(
                "data:image/svg+xml;base64,",
                Base64.encode(bytes(svg))
            )
        );

        return string(abi.encodePacked(
            '{"name":"MATURRA Position #', tokenId.toString(), '",',
            '"description":"A MATURRA Protocol time position. This NFT represents locked USDC capital whose real maturraral value has been computed against live inflation data. The holder can redeem the underlying USDC at maturity.",',
            '"image":"', imageData, '",',
            '"attributes":[',
            '{"trait_type":"Locked USDC","value":"', _formatUSDC(pos.lockedAmount), '"},',
            '{"trait_type":"Maturraral Value","value":"', _formatTimeValue(pos.timeValue), '"},',
            '{"trait_type":"Inflation Rate (BPS)","value":', uint256(pos.inflationBps).toString(), '},',
            '{"trait_type":"Lock Duration (days)","value":', (uint256(pos.lockDuration) / 1 days).toString(), '},',
            '{"trait_type":"Matures At","value":', uint256(pos.maturesAt).toString(), '},',
            '{"trait_type":"Status","value":"', pos.redeemed ? "Redeemed" : (block.timestamp >= pos.maturesAt ? "Ready" : "Locked"), '"}',
            ']}'
        ));
    }

    // ── FORMATTING HELPERS ───────────────────────────────────────────────────

    /// @dev Format USDC amount (6 decimals) to human-readable string
    function _formatUSDC(uint128 amount) internal view returns (string memory) {
        uint256 whole    = amount / 1e6;
        uint256 decimals = (amount % 1e6) / 1e4; // 2 decimal places
        if (decimals == 0) return whole.toString();
        return string(abi.encodePacked(whole.toString(), ".", _pad2(decimals)));
    }

    /// @dev Format basis points to percentage string (228 -> "2.28")
    function _formatBps(uint32 bps) internal view returns (string memory) {
        uint256 whole    = bps / 100;
        uint256 decimals = bps % 100;
        return string(abi.encodePacked(whole.toString(), ".", _pad2(decimals)));
    }

    /// @dev Format time value (18 decimals) to human-readable string (2 dp)
    function _formatTimeValue(uint128 tv) internal view returns (string memory) {
        uint256 whole    = uint256(tv) / 1e18;
        uint256 decimals = (uint256(tv) % 1e18) / 1e16;
        return string(abi.encodePacked(whole.toString(), ".", _pad2(decimals)));
    }

    /// @dev Format unix timestamp to YYYY-MM-DD
    function _formatTimestamp(uint64 ts) internal view returns (string memory) {
        // Simple approximation — close enough for display purposes
        uint256 year  = 1970 + ts / 31557600;
        uint256 month = (ts % 31557600) / 2629800 + 1;
        uint256 day   = (ts % 2629800)  / 86400 + 1;
        return string(abi.encodePacked(
            year.toString(), "-",
            month < 10 ? string(abi.encodePacked("0", month.toString())) : month.toString(), "-",
            day   < 10 ? string(abi.encodePacked("0", day.toString()))   : day.toString()
        ));
    }

    /// @dev Pad number to 2 digits (5 -> "05")
    function _pad2(uint256 n) internal view returns (string memory) {
        if (n < 10) return string(abi.encodePacked("0", n.toString()));
        return n.toString();
    }

    // ════════════════════════════════════════════════════════════════════════
    // SAFETY OVERRIDES
    // ════════════════════════════════════════════════════════════════════════

    /// @dev Prevent transfers to zero address (use vault.redeem() to burn)
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override(ERC721, ERC721Enumerable) returns (address) {
        if (to == address(0) && !hasRole(VAULT_ROLE, msg.sender)) {
            revert TransferToZero();
        }
        return super._update(to, tokenId, auth);
    }

    // ── REQUIRED OVERRIDES ───────────────────────────────────────────────────

    function _increaseBalance(address account, uint128 value)
        internal
        override(ERC721, ERC721Enumerable)
    {
        super._increaseBalance(account, value);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable, ERC2981, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    // ════════════════════════════════════════════════════════════════════════
    // VIEWS
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Days remaining before a position matures. 0 if already matured.
    function daysRemaining(uint256 tokenId) external view returns (uint256) {
        uint64 mat = positions[tokenId].maturesAt;
        if (mat == 0) return 0;
        if (block.timestamp >= mat) return 0;
        return (mat - block.timestamp) / 1 days;
    }

    /// @notice True if position has matured and is ready to redeem
    function isMatured(uint256 tokenId) external view returns (bool) {
        return block.timestamp >= positions[tokenId].maturesAt
               && !positions[tokenId].redeemed;
    }

    /// @notice All token IDs owned by an address
    function positionsOf(address owner)
        external
        view
        returns (uint256[] memory)
    {
        uint256 count = balanceOf(owner);
        uint256[] memory ids = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            ids[i] = tokenOfOwnerByIndex(owner, i);
        }
        return ids;
    }
}
