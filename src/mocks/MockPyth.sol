// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockPyth {
    struct Price {
        int64  price;
        uint64 conf;
        int32  expo;
        uint   publishTime;
    }

    int64  public cpiPrice = 270;
    int32  public expo     = -2;
    uint   public publishTime;

    constructor() { publishTime = block.timestamp; }

    function getPriceNoOlderThan(bytes32, uint) external view returns (Price memory) {
        return Price({ price: cpiPrice, conf: 5, expo: expo, publishTime: publishTime });
    }

    function setPrice(int64 _price) external {
        cpiPrice    = _price;
        publishTime = block.timestamp;
    }
}
