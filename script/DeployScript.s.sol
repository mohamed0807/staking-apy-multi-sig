// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {MultiSigWallet} from "src/MultiSigWallet.sol";
import {Staking} from "src/Staking.sol";

interface IERC20 {
    function decimals() external view returns (uint8);

    function balanceOf(address) external view returns (uint256);

    function transfer(address, uint256) external returns (bool);
}

contract DeployMultisigAndStaking is Script {
    address[] owners;

    function run() external {
        uint256 deployerPK = vm.envUint("PRIVATE_KEY");
        address entryPoint = vm.envAddress("ENTRYPOINT_ADDRESS");
        address stakingToken = vm.envAddress("STAKING_TOKEN_ADDRESS");

        owners.push(vm.envAddress("OWNER_1"));
        owners.push(vm.envAddress("OWNER_2"));
        owners.push(vm.envAddress("OWNER_3"));

        uint256 threshold = vm.envUint("THRESHOLD");
        uint256 minimumStake = vm.envUint("MINIMUM_STAKE");

        vm.startBroadcast(deployerPK);

        MultiSigWallet wallet = new MultiSigWallet(
            owners,
            threshold,
            entryPoint
        );
        Staking staking = new Staking(
            stakingToken,
            minimumStake,
            address(wallet)
        );

        vm.stopBroadcast();

        console.log("Multisig Wallet Deployed at:", address(wallet));
        console.log("Staking Contract Deployed at:", address(staking));
    }
}
