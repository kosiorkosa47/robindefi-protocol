// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title SimplePriceOracle
 * @notice Testnet price oracle for stock token valuation.
 *         Owner-settable prices in ETH (18 decimals).
 *         Production version would use Chainlink / Pyth / Robinhood's own oracle.
 * @dev Price = how much ETH 1 full token (10^decimals) is worth, scaled to 18 decimals.
 */
contract SimplePriceOracle {
    address public owner;

    // token => price in ETH (18 decimals)
    mapping(address => uint256) public prices;
    // token => last update timestamp
    mapping(address => uint256) public lastUpdated;

    event PriceUpdated(address indexed token, uint256 price, uint256 timestamp);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function setPrice(address token, uint256 priceInEth) external onlyOwner {
        prices[token] = priceInEth;
        lastUpdated[token] = block.timestamp;
        emit PriceUpdated(token, priceInEth, block.timestamp);
    }

    function setBatchPrices(
        address[] calldata tokens,
        uint256[] calldata pricesInEth
    ) external onlyOwner {
        require(tokens.length == pricesInEth.length, "Length mismatch");
        for (uint256 i = 0; i < tokens.length; i++) {
            prices[tokens[i]] = pricesInEth[i];
            lastUpdated[tokens[i]] = block.timestamp;
            emit PriceUpdated(tokens[i], pricesInEth[i], block.timestamp);
        }
    }

    /// @notice Returns ETH value of a given token amount
    /// @param token Token address
    /// @param amount Token amount (in token's native decimals)
    /// @param tokenDecimals Token's decimals (e.g., 18)
    /// @return valueInEth ETH value scaled to 18 decimals
    function getValueInEth(
        address token,
        uint256 amount,
        uint8 tokenDecimals
    ) external view returns (uint256 valueInEth) {
        require(prices[token] > 0, "Price not set");
        return (amount * prices[token]) / (10 ** tokenDecimals);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}
