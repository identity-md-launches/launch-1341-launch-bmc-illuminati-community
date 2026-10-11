// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {DeployBMC} from "../script/Deploy.s.sol";
import {HookFlags} from "../src/HookFlags.sol";

contract DeployTest is Test {
    function test_deployPlacesTheHookOnAFlaggedAddressAndWiresIt() public {
        PoolManager manager = new PoolManager(address(this));
        address recipient = makeAddr("communityWallet");
        DeployBMC script = new DeployBMC();
        DeployBMC.Deployed memory d = script.deploy(
            DeployBMC.Config({
                poolManager: IPoolManager(address(manager)),
                feeRecipient: recipient,
                buyFeeBps: script.LAUNCH_BUY_FEE_BPS(),
                sellBurnBps: script.LAUNCH_SELL_BURN_BPS()
            })
        );

        assertEq(d.token.totalSupply(), 1_000_000_000 ether);
        assertEq(d.token.balanceOf(address(script)), d.token.totalSupply(), "minted to whoever deployed it");
        assertEq(d.hook.token(), address(d.token));
        assertEq(d.hook.feeRecipient(), recipient);
        assertEq(d.hook.buyFeeBps(), 100);
        assertEq(d.hook.sellBurnBps(), 100);
        assertEq(address(d.router.poolManager()), address(manager));
        assertTrue(HookFlags.matches(address(d.hook), HookFlags.fromPermissions(d.hook.getHookPermissions())));

        // The launch factory opens the pool on it: ETH against the token at the manifest's terms.
        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(d.token)),
            fee: 12_500,
            tickSpacing: 60,
            hooks: IHooks(address(d.hook))
        });
        vm.prank(makeAddr("launchFactory"));
        manager.initialize(key, uint160(10_000) << 96);
        assertTrue(d.hook.poolInitialized());
    }
}
