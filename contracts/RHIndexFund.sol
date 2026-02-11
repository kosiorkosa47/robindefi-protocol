// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title RHIndexFund
 * @author RobinDeFi Protocol
 * @notice On-chain ETF for Robinhood Chain Stock Tokens.
 *
 *  Problem:  Traditional ETFs charge 0.03–1% annual fees, require custodians,
 *            and are opaque. Retail investors can't create custom indices.
 *
 *  Solution: Permissionless index tokens backed 1:1 by a basket of stock tokens.
 *            Anyone can create a custom index (e.g., "Tech Giants": 40% TSLA,
 *            30% AMZN, 30% PLTR). Minting and redeeming are instant, transparent,
 *            and cost only gas.
 *
 *  Revenue:  Small fee on mint/redeem (configurable, default 0.3%).
 *
 * @dev Each INDEX token is backed by a fixed basket of constituent tokens.
 *      Minting 1 INDEX requires depositing `unitsPerIndex[i]` of each constituent.
 *      Redeeming 1 INDEX returns the same basket minus fees.
 */
contract RHIndexFund is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Constituent {
        address token;
        uint256 unitsPerIndex; // tokens needed per 1 INDEX (in token's decimals)
        string  symbol;
    }

    // ── State ───────────────────────────────────────────────────────────
    address public manager;
    address public feeRecipient;
    uint256 public feeBps; // basis points (30 = 0.3%)
    bool    public paused;

    Constituent[] public constituents;
    uint256 public totalMinted;
    uint256 public totalRedeemed;
    uint256 public totalFeesCollected; // in index token units

    // ── Events ──────────────────────────────────────────────────────────
    event Minted(address indexed user, uint256 indexAmount, uint256 fee);
    event Redeemed(address indexed user, uint256 indexAmount, uint256 fee);
    event FeeUpdated(uint256 oldFee, uint256 newFee);
    event ManagerTransferred(address indexed oldManager, address indexed newManager);
    event Paused(bool isPaused);

    // ── Modifiers ───────────────────────────────────────────────────────
    modifier onlyManager() {
        require(msg.sender == manager, "Not manager");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Fund paused");
        _;
    }

    // ── Constructor ─────────────────────────────────────────────────────
    /// @param name_     Index token name (e.g., "RH Tech Giants Index")
    /// @param symbol_   Index token symbol (e.g., "rhTECH")
    /// @param tokens_   Constituent token addresses
    /// @param units_    Units of each token per 1 INDEX (in token's native decimals)
    /// @param symbols_  Human-readable symbols for each constituent
    /// @param feeBps_   Fee in basis points (e.g., 30 = 0.3%)
    constructor(
        string memory name_,
        string memory symbol_,
        address[] memory tokens_,
        uint256[] memory units_,
        string[] memory symbols_,
        uint256 feeBps_
    ) ERC20(name_, symbol_) {
        require(tokens_.length > 0, "Empty basket");
        require(tokens_.length == units_.length, "Length mismatch");
        require(tokens_.length == symbols_.length, "Length mismatch");
        require(feeBps_ <= 500, "Fee too high"); // max 5%

        manager = msg.sender;
        feeRecipient = msg.sender;
        feeBps = feeBps_;

        for (uint256 i = 0; i < tokens_.length; i++) {
            require(tokens_[i] != address(0), "Zero token address");
            require(units_[i] > 0, "Zero units");
            constituents.push(Constituent({
                token: tokens_[i],
                unitsPerIndex: units_[i],
                symbol: symbols_[i]
            }));
        }
    }

    // ── Core: Mint ──────────────────────────────────────────────────────
    /// @notice Mint index tokens by depositing the full basket.
    /// @param amount Number of INDEX tokens to mint (18 decimals)
    function mint(uint256 amount) external whenNotPaused nonReentrant {
        require(amount > 0, "Zero amount");

        // Pull constituent tokens from sender
        for (uint256 i = 0; i < constituents.length; i++) {
            uint256 needed = (constituents[i].unitsPerIndex * amount) / 1e18;
            require(needed > 0, "Amount too small");
            IERC20(constituents[i].token).safeTransferFrom(msg.sender, address(this), needed);
        }

        // Calculate fee
        uint256 fee = (amount * feeBps) / 10000;
        uint256 userAmount = amount - fee;

        // Mint index tokens
        _mint(msg.sender, userAmount);
        if (fee > 0) {
            _mint(feeRecipient, fee);
            totalFeesCollected += fee;
        }

        totalMinted += amount;
        emit Minted(msg.sender, userAmount, fee);
    }

    // ── Core: Redeem ────────────────────────────────────────────────────
    /// @notice Burn index tokens and receive underlying basket.
    /// @param amount Number of INDEX tokens to redeem (18 decimals)
    function redeem(uint256 amount) external whenNotPaused nonReentrant {
        require(amount > 0, "Zero amount");
        require(balanceOf(msg.sender) >= amount, "Insufficient balance");

        // Calculate fee
        uint256 fee = (amount * feeBps) / 10000;
        uint256 redeemAmount = amount - fee;

        // Burn user's index tokens
        _burn(msg.sender, amount);
        if (fee > 0) {
            _mint(feeRecipient, fee);
            totalFeesCollected += fee;
        }

        // Return constituent tokens
        for (uint256 i = 0; i < constituents.length; i++) {
            uint256 owed = (constituents[i].unitsPerIndex * redeemAmount) / 1e18;
            if (owed > 0) {
                IERC20(constituents[i].token).safeTransfer(msg.sender, owed);
            }
        }

        totalRedeemed += amount;
        emit Redeemed(msg.sender, redeemAmount, fee);
    }

    // ── Views ───────────────────────────────────────────────────────────
    function getConstituentCount() external view returns (uint256) {
        return constituents.length;
    }

    function getConstituents() external view returns (Constituent[] memory) {
        return constituents;
    }

    /// @notice How many of each token needed to mint `indexAmount` INDEX tokens
    function getMintRequirements(uint256 indexAmount)
        external
        view
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        tokens = new address[](constituents.length);
        amounts = new uint256[](constituents.length);
        for (uint256 i = 0; i < constituents.length; i++) {
            tokens[i] = constituents[i].token;
            amounts[i] = (constituents[i].unitsPerIndex * indexAmount) / 1e18;
        }
    }

    /// @notice How many of each token received when redeeming `indexAmount` (after fee)
    function getRedeemOutput(uint256 indexAmount)
        external
        view
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        uint256 fee = (indexAmount * feeBps) / 10000;
        uint256 net = indexAmount - fee;
        tokens = new address[](constituents.length);
        amounts = new uint256[](constituents.length);
        for (uint256 i = 0; i < constituents.length; i++) {
            tokens[i] = constituents[i].token;
            amounts[i] = (constituents[i].unitsPerIndex * net) / 1e18;
        }
    }

    // ── Admin ───────────────────────────────────────────────────────────
    function setFee(uint256 newFeeBps) external onlyManager {
        require(newFeeBps <= 500, "Fee too high");
        emit FeeUpdated(feeBps, newFeeBps);
        feeBps = newFeeBps;
    }

    function setFeeRecipient(address recipient) external onlyManager {
        require(recipient != address(0), "Zero address");
        feeRecipient = recipient;
    }

    function setPaused(bool _paused) external onlyManager {
        paused = _paused;
        emit Paused(_paused);
    }

    function transferManager(address newManager) external onlyManager {
        require(newManager != address(0), "Zero address");
        emit ManagerTransferred(manager, newManager);
        manager = newManager;
    }
}
