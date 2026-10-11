// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BMCToken} from "../src/BMCToken.sol";
import {BMCHook, BMC_HOOK_FLAGS} from "../src/BMCHook.sol";
import {BMCSwapRouter} from "../src/BMCSwapRouter.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {HookDeployer} from "../src/HookDeployer.sol";

/// @title DeployBMC
/// @notice Local rehearsal of what the IMD launch factory does: token, then hook at a mined address,
/// then the ownerless swap router. On the real launch the factory deploys the token and the hook from
/// the manifest; this script is for forks and local chains only and never holds the launch wallet.
contract DeployBMC is Script {
    struct Config {
        IPoolManager poolManager;
        address feeRecipient;
        uint256 buyFeeBps;
        uint256 sellBurnBps;
    }

    struct Deployed {
        BMCToken token;
        BMCHook hook;
        BMCSwapRouter router;
        bytes32 hookSalt;
    }

    /// @notice The launch's own rates: 1% buy fee to the community wallet, 1% of every sale burned.
    uint256 public constant LAUNCH_BUY_FEE_BPS = 100;
    uint256 public constant LAUNCH_SELL_BURN_BPS = 100;

    /// @notice Deploys everything from `config`. Tests call this directly with their own config.
    function deploy(Config memory config) public returns (Deployed memory d) {
        return _deploy(config, address(this));
    }

    /// @dev Local calls CREATE2 from this contract; broadcast CREATE2 uses Foundry's proxy.
    function _deploy(Config memory config, address create2Deployer) internal returns (Deployed memory d) {
        d.token = new BMCToken();
        bytes memory creationCode = abi.encodePacked(
            type(BMCHook).creationCode,
            abi.encode(config.poolManager, address(d.token), config.feeRecipient, config.buyFeeBps, config.sellBurnBps)
        );
        uint160 flags = BMC_HOOK_FLAGS;
        (bytes32 salt, address predicted) = HookDeployer.mine(create2Deployer, creationCode, flags, 500_000);
        d.hookSalt = salt;
        d.hook = new BMCHook{salt: salt}(
            config.poolManager, address(d.token), config.feeRecipient, config.buyFeeBps, config.sellBurnBps
        );
        require(address(d.hook) == predicted, "hook landed on an unexpected address");
        d.router = new BMCSwapRouter(config.poolManager);
    }

    /// @notice Reads POOL_MANAGER and FEE_RECIPIENT from the environment and deploys with the launch rates.
    function run() external returns (Deployed memory d) {
        Config memory config = Config({
            poolManager: IPoolManager(vm.envAddress("POOL_MANAGER")),
            feeRecipient: vm.envAddress("FEE_RECIPIENT"),
            buyFeeBps: LAUNCH_BUY_FEE_BPS,
            sellBurnBps: LAUNCH_SELL_BURN_BPS
        });
        vm.startBroadcast();
        d = _deploy(config, CREATE2_FACTORY);
        vm.stopBroadcast();
        console2.log("BMCToken", address(d.token));
        console2.log("BMCHook", address(d.hook));
        console2.log("BMCSwapRouter", address(d.router));
    }
}
