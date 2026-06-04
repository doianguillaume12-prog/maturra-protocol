// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockTruflation {
    int256  public value     = 2.28e18;
    uint256 public updatedAt;

    constructor() { updatedAt = block.timestamp; }

    function getLatestInflation() external view returns (int256, uint256) {
        return (value, updatedAt);
    }

    function setValue(int256 _value) external {
        value     = _value;
        updatedAt = block.timestamp;
    }
}
