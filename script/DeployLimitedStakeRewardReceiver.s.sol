// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {LimitedStakeRewardReceiver} from "../contracts/LimitedStakeRewardReceiver.sol";

// forge script script/DeployLimitedStakeRewardReceiver.s.sol:DeployLimitedStakeRewardReceiver --rpc-url ${STORY_RPC} --broadcast --sender ${STORY_DEPLOYER_ADDRESS} --priority-gas-price 1 --legacy --verify --verifier=blockscout --verifier-url ${VERIFIER_URL} --private-key ${STORY_PRIVATEKEY}

contract DeployLimitedStakeRewardReceiver is Script {

    function run() public {
        vm.startBroadcast();

        address limitedStakeRewardReceiver = address(new LimitedStakeRewardReceiver());

        console2.log("LimitedStakeRewardReceiver deployed at", limitedStakeRewardReceiver);

        vm.stopBroadcast();
    }
}