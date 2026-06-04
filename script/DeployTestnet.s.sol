// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { MaturraOracle }      from "../src/MaturraOracle.sol";
import { TimeNFT }          from "../src/TimeNFT.sol";
import { MaturraToken }       from "../src/MaturraToken.sol";
import { BurnRouter }       from "../src/BurnRouter.sol";
import { MaturraMarket }      from "../src/MaturraMarket.sol";
import { MaturraVault }       from "../src/MaturraVault.sol";
import { MockTruflation }   from "../src/mocks/MockTruflation.sol";
import { MockPyth }         from "../src/mocks/MockPyth.sol";



contract MockSwapRouter {
    function exactInputSingle(bytes calldata) external pure returns (uint256) {
        return 0;
    }
}

contract MockUSDC {
    mapping(address=>uint256) public balanceOf;
    mapping(address=>mapping(address=>uint256)) public allowance;
    string public name="USD Coin"; string public symbol="USDC"; uint8 public decimals=6;
    function mint(address to,uint256 amt) external { balanceOf[to]+=amt; }
    function approve(address sp,uint256 amt) external returns(bool){ allowance[msg.sender][sp]=amt; return true; }
    function transfer(address to,uint256 amt) external returns(bool){ balanceOf[msg.sender]-=amt; balanceOf[to]+=amt; return true; }
    function transferFrom(address fr,address to,uint256 amt) external returns(bool){ allowance[fr][msg.sender]-=amt; balanceOf[fr]-=amt; balanceOf[to]+=amt; return true; }
}

contract DeployTestnet is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address dao         = vm.envAddress("DAO_ADDRESS");
        address guardian    = vm.envAddress("GUARDIAN_ADDRESS");
        address treasury    = vm.envAddress("TREASURY_ADDRESS");

        vm.startBroadcast(deployerKey);

        MockUSDC usdc = new MockUSDC();
        address SEPOLIA_USDC = address(usdc);
        console2.log("MockUSDC:", SEPOLIA_USDC);

        MockTruflation truflation = new MockTruflation();
        MockPyth       pyth       = new MockPyth();

        MaturraOracle oracle = new MaturraOracle(address(truflation), address(pyth), dao, dao);

        MaturraToken maturra = new MaturraToken(dao, dao, treasury);

        MockSwapRouter swapRouter = new MockSwapRouter();

        BurnRouter burnRouter = new BurnRouter(SEPOLIA_USDC, address(maturra), address(swapRouter), dao);

        maturra.grantRole(keccak256("BURN_ROUTER_ROLE"), address(burnRouter));

        TimeNFT nft = new TimeNFT(dao, address(burnRouter));

        MaturraVault vault = new MaturraVault(SEPOLIA_USDC, address(oracle), address(nft), address(burnRouter), treasury, dao, guardian);

        nft.grantRole(keccak256("VAULT_ROLE"), address(vault));
        vault.setTvlCap(type(uint256).max);

        MaturraMarket market = new MaturraMarket(address(nft), SEPOLIA_USDC, dao, guardian);

        vm.stopBroadcast();

        console2.log("=== MATURRA TESTNET DEPLOYMENT ===");
        console2.log("MockTruflation:", address(truflation));
        console2.log("MockPyth:", address(pyth));
        console2.log("MaturraOracle:", address(oracle));
        console2.log("MaturraToken:", address(maturra));
        console2.log("BurnRouter:", address(burnRouter));
        console2.log("TimeNFT:", address(nft));
        console2.log("MaturraVault:", address(vault));
        console2.log("MaturraMarket:", address(market));
    }
}
