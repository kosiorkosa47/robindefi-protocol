// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title RHStockOption
 * @author RobinDeFi Protocol
 * @notice Peer-to-peer covered call options on Robinhood Chain Stock Tokens.
 *
 *  Problem:  Options trading in TradFi is complex, expensive, and gatekept.
 *            Brokers charge per-contract fees, require approvals, and have
 *            limited hours.
 *
 *  Solution: Anyone can write covered calls by locking stock tokens.
 *            Anyone can buy options by paying the premium in ETH.
 *            Settlement is automatic and trustless. 24/7, no minimum, no approval.
 *
 *  How it works:
 *    1. Writer deposits stock tokens + sets strike price + expiry → option created
 *    2. Buyer pays premium (ETH) → option assigned to buyer
 *    3. Before expiry: buyer exercises (pays strike in ETH → receives tokens)
 *    4. After expiry: writer reclaims tokens + keeps premium
 *
 *  Revenue: Protocol fee on premium (configurable).
 */
contract RHStockOption is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum OptionState { Open, Bought, Exercised, Expired, Cancelled }

    struct Option {
        // Writer (seller) side
        address writer;
        address token;
        uint256 tokenAmount;     // stock tokens locked
        // Terms
        uint256 strikePriceETH;  // ETH buyer pays to exercise (wei)
        uint256 premiumETH;      // ETH buyer pays upfront (wei)
        uint256 expiry;          // timestamp
        // Buyer side
        address buyer;
        // State
        OptionState state;
    }

    // ── State ───────────────────────────────────────────────────────────
    address public owner;
    uint256 public protocolFeeBps; // fee on premium (e.g., 100 = 1%)
    bool    public paused;

    Option[] public options;
    uint256 public totalPremiumVolume;
    uint256 public totalExerciseVolume;
    uint256 public totalFeesCollected;

    // ── Events ──────────────────────────────────────────────────────────
    event OptionWritten(uint256 indexed optionId, address indexed writer, address token, uint256 amount, uint256 strike, uint256 premium, uint256 expiry);
    event OptionBought(uint256 indexed optionId, address indexed buyer, uint256 premium);
    event OptionExercised(uint256 indexed optionId, address indexed buyer, uint256 strikePayment);
    event OptionExpired(uint256 indexed optionId, address indexed writer);
    event OptionCancelled(uint256 indexed optionId, address indexed writer);

    // ── Modifiers ───────────────────────────────────────────────────────
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Market paused");
        _;
    }

    // ── Constructor ─────────────────────────────────────────────────────
    constructor(uint256 protocolFeeBps_) {
        require(protocolFeeBps_ <= 1000, "Fee too high"); // max 10%
        owner = msg.sender;
        protocolFeeBps = protocolFeeBps_;
    }

    // ── Writer: Create Option ───────────────────────────────────────────
    /// @notice Write a covered call option by locking stock tokens.
    /// @param token        Stock token to use as underlying
    /// @param tokenAmount  Amount of tokens to lock
    /// @param strikeETH    Strike price in ETH (wei) - buyer pays this to exercise
    /// @param premiumETH   Premium in ETH (wei) - buyer pays this to acquire the option
    /// @param duration     Seconds until expiry
    function writeOption(
        address token,
        uint256 tokenAmount,
        uint256 strikeETH,
        uint256 premiumETH,
        uint256 duration
    ) external whenNotPaused nonReentrant returns (uint256 optionId) {
        require(tokenAmount > 0, "Zero tokens");
        require(strikeETH > 0, "Zero strike");
        require(premiumETH > 0, "Zero premium");
        require(duration >= 1 hours, "Min 1 hour");
        require(duration <= 90 days, "Max 90 days");

        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);

        optionId = options.length;
        options.push(Option({
            writer: msg.sender,
            token: token,
            tokenAmount: tokenAmount,
            strikePriceETH: strikeETH,
            premiumETH: premiumETH,
            expiry: block.timestamp + duration,
            buyer: address(0),
            state: OptionState.Open
        }));

        emit OptionWritten(optionId, msg.sender, token, tokenAmount, strikeETH, premiumETH, block.timestamp + duration);
    }

    // ── Buyer: Purchase Option ──────────────────────────────────────────
    /// @notice Buy an open option by paying the premium in ETH.
    function buyOption(uint256 optionId) external payable whenNotPaused nonReentrant {
        Option storage opt = options[optionId];
        require(opt.state == OptionState.Open, "Not available");
        require(block.timestamp < opt.expiry, "Expired");
        require(msg.value >= opt.premiumETH, "Insufficient premium");

        opt.buyer = msg.sender;
        opt.state = OptionState.Bought;

        // Protocol fee
        uint256 fee = (opt.premiumETH * protocolFeeBps) / 10000;
        uint256 writerPayment = opt.premiumETH - fee;
        totalFeesCollected += fee;
        totalPremiumVolume += opt.premiumETH;

        // Pay writer (premium minus fee)
        (bool sent, ) = opt.writer.call{value: writerPayment}("");
        require(sent, "Premium transfer failed");

        // Refund excess
        uint256 excess = msg.value - opt.premiumETH;
        if (excess > 0) {
            (bool refunded, ) = msg.sender.call{value: excess}("");
            require(refunded, "Refund failed");
        }

        emit OptionBought(optionId, msg.sender, opt.premiumETH);
    }

    // ── Buyer: Exercise Option ──────────────────────────────────────────
    /// @notice Exercise the option before expiry: pay strike price, receive tokens.
    function exerciseOption(uint256 optionId) external payable whenNotPaused nonReentrant {
        Option storage opt = options[optionId];
        require(opt.state == OptionState.Bought, "Not exercisable");
        require(msg.sender == opt.buyer, "Not buyer");
        require(block.timestamp < opt.expiry, "Expired");
        require(msg.value >= opt.strikePriceETH, "Insufficient strike payment");

        opt.state = OptionState.Exercised;
        totalExerciseVolume += opt.strikePriceETH;

        // Send stock tokens to buyer
        IERC20(opt.token).safeTransfer(opt.buyer, opt.tokenAmount);

        // Send strike payment to writer
        (bool sent, ) = opt.writer.call{value: opt.strikePriceETH}("");
        require(sent, "Strike transfer failed");

        // Refund excess
        uint256 excess = msg.value - opt.strikePriceETH;
        if (excess > 0) {
            (bool refunded, ) = msg.sender.call{value: excess}("");
            require(refunded, "Refund failed");
        }

        emit OptionExercised(optionId, msg.sender, opt.strikePriceETH);
    }

    // ── Writer: Expire / Cancel ─────────────────────────────────────────
    /// @notice Reclaim tokens after option expires unexercised.
    function expireOption(uint256 optionId) external nonReentrant {
        Option storage opt = options[optionId];
        require(opt.writer == msg.sender, "Not writer");
        require(opt.state == OptionState.Bought, "Not bought");
        require(block.timestamp >= opt.expiry, "Not expired yet");

        opt.state = OptionState.Expired;
        IERC20(opt.token).safeTransfer(opt.writer, opt.tokenAmount);

        emit OptionExpired(optionId, msg.sender);
    }

    /// @notice Cancel an unbought option and reclaim tokens.
    function cancelOption(uint256 optionId) external nonReentrant {
        Option storage opt = options[optionId];
        require(opt.writer == msg.sender, "Not writer");
        require(opt.state == OptionState.Open, "Not open");

        opt.state = OptionState.Cancelled;
        IERC20(opt.token).safeTransfer(opt.writer, opt.tokenAmount);

        emit OptionCancelled(optionId, msg.sender);
    }

    // ── Views ───────────────────────────────────────────────────────────
    function getOptionCount() external view returns (uint256) {
        return options.length;
    }

    function getOpenOptions() external view returns (uint256[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < options.length; i++) {
            if (options[i].state == OptionState.Open && block.timestamp < options[i].expiry) {
                count++;
            }
        }
        uint256[] memory result = new uint256[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < options.length; i++) {
            if (options[i].state == OptionState.Open && block.timestamp < options[i].expiry) {
                result[idx++] = i;
            }
        }
        return result;
    }

    // ── Admin ───────────────────────────────────────────────────────────
    function setProtocolFee(uint256 newFeeBps) external onlyOwner {
        require(newFeeBps <= 1000, "Fee too high");
        protocolFeeBps = newFeeBps;
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }

    function withdrawFees() external onlyOwner {
        uint256 bal = address(this).balance;
        // Only withdraw accumulated protocol fees, not locked strike payments
        // In production, track exact fee balance separately
        (bool sent, ) = owner.call{value: bal}("");
        require(sent, "Withdrawal failed");
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        owner = newOwner;
    }
}
