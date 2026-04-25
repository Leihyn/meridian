// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {InterestRateModel} from "../src/InterestRateModel.sol";
import {YieldOracle} from "../src/YieldOracle.sol";
import {CollateralManager} from "../src/CollateralManager.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {LiquidationEngine} from "../src/LiquidationEngine.sol";
import {IBCReceiver} from "../src/IBCReceiver.sol";

contract DeployMeridian is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer:", deployer);
        console.log("Balance:", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy InterestRateModel (no dependencies)
        InterestRateModel irm = new InterestRateModel();
        console.log("InterestRateModel:", address(irm));

        // 2. Deploy YieldOracle
        YieldOracle oracle = new YieldOracle(deployer);
        console.log("YieldOracle:", address(oracle));

        // 3. Deploy CollateralManager
        CollateralManager cm = new CollateralManager(deployer, address(oracle));
        console.log("CollateralManager:", address(cm));

        // 4. Deploy LendingPool
        // Use the native GAS token as the lending asset
        // On MiniEVM, we need a wrapped version or use a mock for now
        // For hackathon: deploy a simple MockINIT token as the lending asset
        MockLendingToken lendingToken = new MockLendingToken();
        console.log("LendingToken (MockINIT):", address(lendingToken));

        LendingPool pool = new LendingPool(
            address(lendingToken),
            address(cm),
            address(irm),
            deployer
        );
        console.log("LendingPool:", address(pool));

        // 5. Deploy LiquidationEngine
        LiquidationEngine engine = new LiquidationEngine(
            address(cm),
            address(pool),
            "channel-0", // IBC channel to L1 (will update after relayer setup)
            "0x47D11C25C326084F4206DA7A420D6FB7D0FC0992", // L1 Move module address
            deployer
        );
        console.log("LiquidationEngine:", address(engine));

        // 6. Deploy IBCReceiver
        IBCReceiver receiver = new IBCReceiver(
            address(cm),
            address(oracle),
            deployer
        );
        console.log("IBCReceiver:", address(receiver));

        // 7. Grant roles
        // CollateralManager: grant MANAGER_ROLE to pool, engine, receiver
        cm.grantRole(cm.MANAGER_ROLE(), address(pool));
        cm.grantRole(cm.MANAGER_ROLE(), address(engine));
        cm.grantRole(cm.MANAGER_ROLE(), address(receiver));

        // LendingPool: grant POOL_ADMIN_ROLE to engine
        pool.grantRole(pool.POOL_ADMIN_ROLE(), address(engine));

        // YieldOracle: grant REPORTER_ROLE to receiver
        oracle.grantRole(oracle.REPORTER_ROLE(), address(receiver));

        // 8. Mint initial lending tokens to deployer (for testing)
        lendingToken.mint(deployer, 1_000_000e18);

        vm.stopBroadcast();

        console.log("\n--- Deployment Complete ---");
        console.log("InterestRateModel:", address(irm));
        console.log("YieldOracle:", address(oracle));
        console.log("CollateralManager:", address(cm));
        console.log("LendingToken:", address(lendingToken));
        console.log("LendingPool:", address(pool));
        console.log("LiquidationEngine:", address(engine));
        console.log("IBCReceiver:", address(receiver));
    }
}

/// @dev Simple ERC20 for lending asset on L2
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockLendingToken is ERC20 {
    constructor() ERC20("Meridian INIT", "mINIT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
