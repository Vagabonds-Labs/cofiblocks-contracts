mod test_swap {
    use contracts::swap::{ISwapDispatcher, ISwapDispatcherTrait, SWAP_TOKEN, MainnetConfig};
    use openzeppelin::interfaces::token::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use openzeppelin::utils::serde::SerializedAppend;
    use snforge_std::{
        CheatSpan, ContractClassTrait, DeclareResultTrait, cheat_caller_address, declare,
    };
    use starknet::ContractAddress;
    use starknet::syscalls::call_contract_syscall;

    fn OWNER() -> ContractAddress {
        'OWNER'.try_into().unwrap()
    }

    fn CONSUMER() -> ContractAddress {
        'CONSUMER'.try_into().unwrap()
    }

    const STRK_TOKEN_MINTER_ADDRESS: felt252 =
        0x0594c1582459ea03f77deaf9eb7e3917d6994a03c13405ba42867f83d85f085d;

    const USDT_TOKEN_MINTER_ADDRESS: felt252 =
        0x074761a8d48ce002963002becc6d9c3dd8a2a05b1075d55e5967f42296f16bd0;

    const ONE_E18: u256 = 1000000000000000000_u256;
    const ONE_E6: u256 = 1000000_u256;

    fn deploy_swap() -> ISwapDispatcher {
        let contract = declare("Swap").unwrap().contract_class();

        let mut calldata: Array<felt252> = array![];
        calldata.append_serde(OWNER()); // admin

        let (contract_address, _) = contract.deploy(@calldata).unwrap();
        let swap = ISwapDispatcher { contract_address };
        swap
    }

    #[test]
    #[fork("MAINNET_LATEST")]
    fn test_swap_strk() {
        let swap = deploy_swap();

        // Fund buyer wallet
        let amount_to_mint = swap.get_swap_price(SWAP_TOKEN::STRK, 10 * ONE_E6);
        let amount_to_swap = 10 * ONE_E6;
        let minter_address = STRK_TOKEN_MINTER_ADDRESS.try_into().unwrap();
        let strk_address = MainnetConfig::STRK_ADDRESS.try_into().unwrap();
        let strk_dispatcher = IERC20Dispatcher { contract_address: strk_address };
        let usdc_token_address = MainnetConfig::USDC_ADDRESS.try_into().unwrap();
        let usdc_token_dispatcher = IERC20Dispatcher { contract_address: usdc_token_address };

        cheat_caller_address(strk_address, minter_address, CheatSpan::TargetCalls(1));
        let mut calldata = array![];
        calldata.append_serde(CONSUMER());
        calldata.append_serde(amount_to_mint);
        call_contract_syscall(
            strk_address, selector!("permissioned_mint"), calldata.span()
        ).unwrap();
        assert(strk_dispatcher.balance_of(CONSUMER()) >= amount_to_mint, 'invalid balance');
        // Swap STRK for USDC
        cheat_caller_address(strk_address, CONSUMER(), CheatSpan::TargetCalls(1));
        strk_dispatcher.approve(swap.contract_address, amount_to_mint);

        // Swap a little less than total to pay for slippage
        cheat_caller_address(swap.contract_address, CONSUMER(), CheatSpan::TargetCalls(1));
        swap.swap_token_for_usdc(SWAP_TOKEN::STRK, amount_to_swap);

        // check that there is USDC in the contract
        let usdc_in_contract = usdc_token_dispatcher.balance_of(swap.contract_address);
        assert(usdc_in_contract > 0, 'failed to swap STRK');

        // Claim USDC
        cheat_caller_address(swap.contract_address, CONSUMER(), CheatSpan::TargetCalls(1));
        swap.claim_usdc();
        // Check that the contract now has the expected balance in usdt
        let usdc_token_address = MainnetConfig::USDC_ADDRESS.try_into().unwrap();
        let usdc_token_dispatcher = IERC20Dispatcher { contract_address: usdc_token_address };
        let usdc_of_consumer = usdc_token_dispatcher.balance_of(CONSUMER());
        println!("usdc_of_consumer after swap strk: {:?}", usdc_of_consumer);
        assert(usdc_of_consumer > 0, 'invalid usdc of consumer');
    }

    #[test]
    #[fork("MAINNET_LATEST")]
    fn test_swap_usdt() {
        let swap = deploy_swap();

        // Fund buyer wallet
        let amount_to_mint = 10 * ONE_E6 + 1_000_000;
        let amount_to_swap = 10 * ONE_E6;
        let minter_address = USDT_TOKEN_MINTER_ADDRESS.try_into().unwrap();
        let usdt_address = MainnetConfig::USDT_ADDRESS.try_into().unwrap();
        let usdt_dispatcher = IERC20Dispatcher { contract_address: usdt_address };
        let usdc_token_address = MainnetConfig::USDC_ADDRESS.try_into().unwrap();
        let usdc_token_dispatcher = IERC20Dispatcher { contract_address: usdc_token_address };

        cheat_caller_address(usdt_address, minter_address, CheatSpan::TargetCalls(1));
        let mut calldata = array![];
        calldata.append_serde(CONSUMER());
        calldata.append_serde(amount_to_mint);
        call_contract_syscall(
            usdt_address, selector!("permissioned_mint"), calldata.span()
        ).unwrap();
        assert(usdt_dispatcher.balance_of(CONSUMER()) >= amount_to_mint, 'invalid balance');
        // Swap USDT for USDC
        cheat_caller_address(usdt_address, CONSUMER(), CheatSpan::TargetCalls(1));
        usdt_dispatcher.approve(swap.contract_address, amount_to_mint);

        // Swap a little less than total to pay for slippage
        cheat_caller_address(swap.contract_address, CONSUMER(), CheatSpan::TargetCalls(1));
        swap.swap_token_for_usdc(SWAP_TOKEN::USDT, amount_to_swap);

        // check that there is USDC in the contract
        let usdc_in_contract = usdc_token_dispatcher.balance_of(swap.contract_address);
        assert(usdc_in_contract > 0, 'failed to swap USDT');

        // Claim USDC
        cheat_caller_address(swap.contract_address, CONSUMER(), CheatSpan::TargetCalls(1));
        swap.claim_usdc();
        // Check that the contract now has the expected balance in usdt
        let usdc_token_address = MainnetConfig::USDC_ADDRESS.try_into().unwrap();
        let usdc_token_dispatcher = IERC20Dispatcher { contract_address: usdc_token_address };
        let usdc_of_consumer = usdc_token_dispatcher.balance_of(CONSUMER());
        println!("usdc_of_consumer afer swap usdt: {:?}", usdc_of_consumer);
        assert(usdc_of_consumer > 0, 'invalid usdc of consumer');
    }
}
