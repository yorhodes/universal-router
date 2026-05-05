// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {DeployUniversalRouter} from '../DeployUniversalRouter.s.sol';

contract DeployEthereum is DeployUniversalRouter {
    function setUp() public virtual override {
        params = DeploymentParameters({
            weth9: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
            v2Factory: 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f,
            v3Factory: 0x1F98431c8aD98523631AE4a59f267346ea31F984,
            pairInitCodeHash: 0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f,
            poolInitCodeHash: 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54,
            v4PoolManager: 0x000000000004444c5dc75cB358380D2e3dE08A90,
            veloV2Factory: UNSUPPORTED_PROTOCOL,
            veloCLFactory: UNSUPPORTED_PROTOCOL,
            veloV2InitCodeHash: BYTES32_ZERO,
            veloCLInitCodeHash: BYTES32_ZERO,
            veloCLFactory2: UNSUPPORTED_PROTOCOL,
            veloCLInitCodeHash2: BYTES32_ZERO,
            veloCLFactory3: UNSUPPORTED_PROTOCOL,
            veloCLInitCodeHash3: BYTES32_ZERO
        });

        outputFilename = 'ethereum.json';
    }
}
