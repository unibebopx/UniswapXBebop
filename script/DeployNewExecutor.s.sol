import "forge-std/console2.sol";
import "forge-std/Script.sol";
import {SwapRouter02ExecutorNew} from "src/sample-executors/SwapRouter02ExecutorNew.sol";
import {ISwapRouter02} from "../src/external/ISwapRouter02.sol";
import {IBebopSettlement} from "../../BebopSettlement/src/interface/IBebopSettlement.sol";
import {IReactor} from "../src/interfaces/IReactor.sol";

contract DeploySwapRouter02Executor is Script {
    function setUp() public {}

    function run() public returns (SwapRouter02ExecutorNew executor) {
        uint256 privateKey = vm.envUint("FOUNDRY_PRIVATE_KEY");
        IReactor reactor = IReactor(
            vm.envAddress("FOUNDRY_SWAPROUTER02EXECUTOR_DEPLOY_REACTOR")
        );
        address whitelistedCaller = vm.envAddress(
            "FOUNDRY_SWAPROUTER02EXECUTOR_DEPLOY_WHITELISTED_CALLER"
        );
        address owner = vm.envAddress(
            "FOUNDRY_SWAPROUTER02EXECUTOR_DEPLOY_OWNER"
        );
        ISwapRouter02 swapRouter02 = ISwapRouter02(
            vm.envAddress("FOUNDRY_SWAPROUTER02EXECUTOR_DEPLOY_SWAPROUTER02")
        );
        IBebopSettlement bebop = IBebopSettlement(
            vm.envAddress("FOUNDRY_SWAPROUTER02EXECUTOR_DEPLOY_BEBOP")
        );

        vm.startBroadcast(privateKey);
        executor = new SwapRouter02ExecutorNew{salt: 0x00}(
            whitelistedCaller,
            reactor,
            owner,
            swapRouter02,
            bebop
        );
        vm.stopBroadcast();

        console2.log("SwapRouter02ExecutorNew", address(executor));
        console2.log("owner", executor.owner());
    }
}
