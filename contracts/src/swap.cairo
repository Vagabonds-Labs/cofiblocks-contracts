// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts for Cairo ^0.15.0

use ekubo::types::delta::Delta;
use ekubo::types::keys::PoolKey;
use starknet::ContractAddress;

#[derive(Copy, Drop, Serde, PartialEq)]
pub enum PAYMENT_TOKEN {
    STRK,
    USDC_BRIDGED,
    USDT,
}

#[derive(Drop, Copy, Serde)]
struct SwapAfterLockParameters {
    contract_address: ContractAddress,
    to: ContractAddress,
    sell_token_address: ContractAddress,
    sell_token_amount: u256,
    buy_token_address: ContractAddress,
    pool_key: PoolKey,
    sqrt_ratio_distance: u256,
}

#[derive(Copy, Drop, Serde)]
struct SwapResult {
    delta: Delta,
}

#[starknet::interface]
pub trait ISwap<ContractState> {
    fn locked(ref self: ContractState, id: u32, data: Array<felt252>) -> Array<felt252>;
    fn withdraw(ref self: ContractState, token: PAYMENT_TOKEN);
    fn swap_token_for_usdc(ref self: ContractState, token: PAYMENT_TOKEN, amountUSDC: u256);
    fn get_swap_price(self: @ContractState, token: PAYMENT_TOKEN, amountUSDC: u256) -> u256;
    fn get_pending_claim(self: @ContractState) -> u256;
    fn claim_usdc(ref self: ContractState);
}

pub mod MainnetConfig {
    pub const USDT_ADDRESS: felt252 =
        0x068f5c6a61780768455de69077e07e89787839bf8166decfbf92b645209c0fb8;

    pub const STRK_ADDRESS: felt252 =
        0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d;

    pub const USDC_BRIDGED_ADDRESS: felt252 =
        0x053c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8;

    pub const USDC_ADDRESS: felt252 =
        0x033068F6539f8e6e6b131e6B2B814e6c34A5224bC66947c47DaB9dFeE93b35fb;

    // https://app.ekubo.org/starknet/positions/new?baseCurrency=0x33068f6539f8e6e6b131e6b2b814e6c34a5224bc66947c47dab9dfee93b35fb&quoteCurrency=0x068f5c6a61780768455de69077e07e89787839bf8166decfbf92b645209c0fb8&step=1&poolType=concentrated&initialTick=16&fee=34028236692093847977029636859101184&tickSpacing=200&tickLower=-400&tickUpper=1200
    pub const USDT_USDC_POOL_KEY: u128 = 34028236692093847977029636859101184;
    pub const USDT_USDC_TICK_SPACING: u128 = 200;
    pub const USDT_SLIPPAGE_PERCENTAGE: u256 = 8; // 0.08%

    // https://app.ekubo.org/starknet/positions/new?baseCurrency=0x33068f6539f8e6e6b131e6b2b814e6c34a5224bc66947c47dab9dfee93b35fb&quoteCurrency=0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d&step=1&poolType=concentrated&initialTick=16&fee=170141183460469235273462165868118016&tickSpacing=1000&tickLower=30158000&tickUpper=30190000
    pub const STARK_USDC_POOL_KEY: u128 = 170141183460469235273462165868118016;
    pub const STARK_USDC_TICK_SPACING: u128 = 1000;
    pub const STARK_SLIPPAGE_PERCENTAGE: u256 = 5; // 0.05%

    // https://app.ekubo.org/starknet/positions/new?baseCurrency=0x33068f6539f8e6e6b131e6b2b814e6c34a5224bc66947c47dab9dfee93b35fb&quoteCurrency=0x53c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8&step=1&poolType=concentrated&initialTick=16&fee=0&tickSpacing=101&tickLower=-404&tickUpper=505
    pub const USDC_BRIDGED_FEE: u128 = 0;
    pub const USDC_BRIDGED_TICK_SPACING: u128 = 101;
    pub const USDC_BRIDGED_SLIPPAGE_PERCENTAGE: u256 = 5; // 0.05%

    pub const EKUBO_ADDRESS: felt252 =
        0x00000005dd3D2F4429AF886cD1a3b08289DBcEa99A294197E9eB43b0e0325b4b;
}

#[starknet::contract]
mod Swap {
    use ekubo::components::shared_locker::{check_caller_is_core, handle_delta};
    use ekubo::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait, SwapParameters};
    use ekubo::types::i129::i129;
    use ekubo::types::keys::PoolKey;
    use openzeppelin::access::accesscontrol::{AccessControlComponent, DEFAULT_ADMIN_ROLE};
    use openzeppelin::introspection::src5::SRC5Component;
    use openzeppelin::interfaces::token::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use openzeppelin::upgrades::UpgradeableComponent;
    use openzeppelin::interfaces::upgrades::IUpgradeable;
    use starknet::storage::Map;
    use starknet::{ClassHash, ContractAddress, get_caller_address, get_contract_address};
    use super::{MainnetConfig, PAYMENT_TOKEN, SwapAfterLockParameters, SwapResult};

    component!(path: SRC5Component, storage: src5, event: SRC5Event);
    component!(path: AccessControlComponent, storage: accesscontrol, event: AccessControlEvent);
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);


    // SRC5
    #[abi(embed_v0)]
    impl SRC5Impl = SRC5Component::SRC5Impl<ContractState>;

    // Access Control
    #[abi(embed_v0)]
    impl AccessControlImpl =
        AccessControlComponent::AccessControlImpl<ContractState>;
    impl AccessControlInternalImpl = AccessControlComponent::InternalImpl<ContractState>;

    // Upgradeable
    impl UpgradeableInternalImpl = UpgradeableComponent::InternalImpl<ContractState>;

    const MIN_SQRT_RATIO: u256 = 18446748437148339061;
    const MAX_SQRT_RATIO: u256 = 6277100250585753475930931601400621808602321654880405518632;
    const TWO_E128: u256 = 340282366920938463463374607431768211456;
    const ONE_E12: u256 = 1000000000000;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        #[substorage(v0)]
        accesscontrol: AccessControlComponent::Storage,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,
        transferrable_usdc_amounts: Map<ContractAddress, u256>,
        ekubo: ICoreDispatcher,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        SRC5Event: SRC5Component::Event,
        #[flat]
        AccessControlEvent: AccessControlComponent::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,
    }

    ///
    /// Constructor.
    /// # Arguments
    /// * `cofi_collection_address` - The address of the CofiCollection contract
    /// * `ekubo_address` - The address of the Ekubo contract
    /// * `admin` - The address of the admin role
    /// * `market_fee` - The fee that the marketplace will take from the sales
    /// * `base_uri` - The base uri for the NFTs metadata. Should contain `{id}` so that metadata
    /// gets
    ///    replace per each token id. Example: https://example.com/metadata/{id}.json
    ///
    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin: ContractAddress,
    ) {
        self.accesscontrol.initializer();
        self.accesscontrol._grant_role(DEFAULT_ADMIN_ROLE, admin);
        self
            .ekubo
            .write(
                ICoreDispatcher {
                    contract_address: MainnetConfig::EKUBO_ADDRESS.try_into().unwrap(),
                },
            );
    }

    #[abi(embed_v0)]
    impl SwapImpl of super::ISwap<ContractState> {
        fn locked(ref self: ContractState, id: u32, data: Array<felt252>) -> Array<felt252> {
            // This function can only be called by ekubo
            let ekubo = self.ekubo.read();
            check_caller_is_core(ekubo);

            // Deserialize data
            let mut input_span = data.span();
            let mut params = Serde::<SwapAfterLockParameters>::deserialize(ref input_span)
                .expect('Invalid callback data');

            let is_token1 = params.pool_key.token1 == params.sell_token_address;
            // Swap
            assert(params.sell_token_amount.high == 0, 'Overflow: Unsupported amount');
            let pool_price = ekubo.get_pool_price(params.pool_key);
            let sqrt_ratio_limit = self
                .compute_sqrt_ratio_limit(
                    pool_price.sqrt_ratio,
                    params.sqrt_ratio_distance,
                    is_token1,
                    MIN_SQRT_RATIO,
                    MAX_SQRT_RATIO,
                );

            let swap_params = SwapParameters {
                amount: i129 { mag: params.sell_token_amount.low, sign: false },
                is_token1,
                sqrt_ratio_limit,
                skip_ahead: 100,
            };
            let mut delta = ekubo.swap(params.pool_key, swap_params);

            let pay_amount = if is_token1 {
                delta.amount1
            } else {
                delta.amount0
            };

            let buy_amount = if is_token1 {
                delta.amount0
            } else {
                delta.amount1
            };

            // Pay the tokens we owe for the swap
            handle_delta(
                core: ekubo,
                token: params.sell_token_address,
                delta: pay_amount,
                recipient: params.to,
            );

            // Receive the tokens we bought
            handle_delta(
                core: ekubo,
                token: params.buy_token_address,
                delta: buy_amount,
                recipient: params.to,
            );

            let swap_result = SwapResult { delta };
            let mut arr: Array<felt252> = ArrayTrait::new();
            Serde::serialize(@swap_result, ref arr);
            arr
        }

        fn withdraw(ref self: ContractState, token: PAYMENT_TOKEN) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            let token_address = match token {
                PAYMENT_TOKEN::STRK => MainnetConfig::STRK_ADDRESS.try_into().unwrap(),
                PAYMENT_TOKEN::USDC_BRIDGED => MainnetConfig::USDC_BRIDGED_ADDRESS.try_into().unwrap(),
                PAYMENT_TOKEN::USDT => MainnetConfig::USDT_ADDRESS.try_into().unwrap(),
            };
            let token_dispatcher = IERC20Dispatcher { contract_address: token_address };
            let balance = token_dispatcher.balance_of(get_contract_address());
            assert(balance >= 0, 'No tokens to withdraw');
            let transfer = token_dispatcher.transfer(get_caller_address(), balance);
            assert(transfer, 'Error withdrawing');
        }

        fn swap_token_for_usdc(ref self: ContractState, token: PAYMENT_TOKEN, amountUSDC: u256) {
            //assert(token == PAYMENT_TOKEN::STRK, 'STRK not supported for now');
            assert(amountUSDC > 0, 'Amount must be greater than 0');
            let token_address = match token {
                PAYMENT_TOKEN::STRK => MainnetConfig::STRK_ADDRESS.try_into().unwrap(),
                PAYMENT_TOKEN::USDC_BRIDGED => MainnetConfig::USDC_BRIDGED_ADDRESS.try_into().unwrap(),
                PAYMENT_TOKEN::USDT => MainnetConfig::USDT_ADDRESS.try_into().unwrap()
            };
            let mut amount_to_transfer = amountUSDC;
            if token == PAYMENT_TOKEN::STRK {
                amount_to_transfer = self.usdc_to_strk_wei(amountUSDC);
            } else if token == PAYMENT_TOKEN::USDT {
                amount_to_transfer = self.usdc_to_usdt(amountUSDC);
            } else if token == PAYMENT_TOKEN::USDC_BRIDGED {
                let slippage = amountUSDC * MainnetConfig::USDC_BRIDGED_SLIPPAGE_PERCENTAGE / 100;
                amount_to_transfer = amountUSDC + slippage;
            }
            self.transfer_token(token_address, amount_to_transfer, get_caller_address());
            self.transferrable_usdc_amounts.write(get_caller_address(), amountUSDC);
            self._swap_token_for_usdc(token, amount_to_transfer);
        }

        fn get_swap_price(self: @ContractState, token: PAYMENT_TOKEN, amountUSDC: u256) -> u256 {
            //assert(token == PAYMENT_TOKEN::STRK, 'STRK not supported for now');
            assert(amountUSDC > 0, 'Amount must be greater than 0');
            let mut amount_to_transfer = amountUSDC;
            if token == PAYMENT_TOKEN::STRK {
                amount_to_transfer = self.usdc_to_strk_wei(amountUSDC);
            } else if token == PAYMENT_TOKEN::USDT {
                amount_to_transfer = self.usdc_to_usdt(amountUSDC);
            } else if token == PAYMENT_TOKEN::USDC_BRIDGED {
                let slippage = amountUSDC * MainnetConfig::USDC_BRIDGED_SLIPPAGE_PERCENTAGE / 100;
                amount_to_transfer = amountUSDC + slippage;
            }
            amount_to_transfer
        }

        fn get_pending_claim(self: @ContractState) -> u256 {
            let caller = get_caller_address();
            let usdc_amount = self.transferrable_usdc_amounts.read(caller);
            assert(usdc_amount > 0, 'No USDC to claim');
            usdc_amount
        }

        fn claim_usdc(ref self: ContractState) {
            let caller = get_caller_address();
            let usdc_amount = self.transferrable_usdc_amounts.read(caller);
            assert(usdc_amount > 0, 'No USDC to claim');
            self.transferrable_usdc_amounts.write(caller, 0);
            let token_dispatcher = IERC20Dispatcher { 
                contract_address: MainnetConfig::USDC_ADDRESS.try_into().unwrap() 
            };
            let transfer = token_dispatcher.transfer(caller, usdc_amount);
            assert(transfer, 'Error claiming USDC');
        }
    }

    #[abi(embed_v0)]
    impl UpgradeableImpl of IUpgradeable<ContractState> {
        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            // This function can only be called by the owner
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            // Replace the class hash upgrading the contract
            self.upgradeable.upgrade(new_class_hash);
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {

        fn transfer_token(
            ref self: ContractState, token_address: ContractAddress, amount: u256, buyer: ContractAddress
        ) {
            let token_dispatcher = IERC20Dispatcher { contract_address: token_address };
            let contract_address = get_contract_address();
            assert(
                token_dispatcher.balance_of(buyer) >= amount, 'insufficient funds',
            );
            assert(
                token_dispatcher.allowance(buyer, contract_address) >= amount,
                'insufficient allowance',
            );
            let success = token_dispatcher.transfer_from(buyer, contract_address, amount);
            assert(success, 'Error transferring tokens');
        }

        fn usdc_to_strk_wei(self: @ContractState, amount_usdc: u256) -> u256 {
            let ekubo = self.ekubo.read();
            let usdc_stark_pool_key = PoolKey {
                token0: MainnetConfig::USDC_ADDRESS.try_into().unwrap(),
                token1: MainnetConfig::STRK_ADDRESS.try_into().unwrap(),
                fee: MainnetConfig::STARK_USDC_POOL_KEY,
                tick_spacing: MainnetConfig::STARK_USDC_TICK_SPACING,
                extension: 0x00.try_into().unwrap(),
            };
            let pool_price = ekubo.get_pool_price(usdc_stark_pool_key);

            let scale = 1_000_000_000_000_000_000;

            // To extract the price, formula is ((sqrt_ratio)/(2^128)) ^ 2.
            // USDC has 6 decimals meanwhile STRK has 18 decimals. So padding is needed.
            let price_without_pow = (pool_price.sqrt_ratio * scale) / TWO_E128;
            let stark_price = price_without_pow * price_without_pow / scale;
            // The amount of starks expresed in 10^6 representation (6 decimals)
            let starks_required = (amount_usdc * stark_price) / scale;
            // output should be in 10^18 representation (wei) so padding with 12 zeros
            let slippage = starks_required * MainnetConfig::STARK_SLIPPAGE_PERCENTAGE / 100;
            let result = starks_required + slippage;
            result
        }

        fn usdc_to_usdt(self: @ContractState, amount_usdc: u256) -> u256 {
            let ekubo = self.ekubo.read();
            let usdc_usdt_pool_key = PoolKey {
                token0: MainnetConfig::USDC_ADDRESS.try_into().unwrap(),
                token1: MainnetConfig::USDT_ADDRESS.try_into().unwrap(),
                fee: MainnetConfig::USDT_USDC_POOL_KEY,
                tick_spacing: MainnetConfig::USDT_USDC_TICK_SPACING,
                extension: 0x00.try_into().unwrap(),
            };
            let pool_price = ekubo.get_pool_price(usdc_usdt_pool_key);

            let scale = 1_000_000_000_000_000_000;

            // To extract the price, formula is ((sqrt_ratio)/(2^128)) ^ 2.
            let price_without_pow = (pool_price.sqrt_ratio * scale) / TWO_E128;
            let usdt_price = price_without_pow * price_without_pow / scale;

            // The amount of usdt expresed in 10^6 representation (6 decimals)
            let usdt_required = (amount_usdc * scale) / usdt_price;
            let slippage = usdt_required * MainnetConfig::USDT_SLIPPAGE_PERCENTAGE / 100;
            usdt_required + slippage
        }

        fn compute_sqrt_ratio_limit(
            ref self: ContractState,
            sqrt_ratio: u256,
            distance: u256,
            is_token1: bool,
            min: u256,
            max: u256,
        ) -> u256 {
            let mut sqrt_ratio_limit = if is_token1 {
                if (distance > max) {
                    max
                } else {
                    sqrt_ratio + distance
                }
            } else {
                if (distance > sqrt_ratio) {
                    min
                } else {
                    sqrt_ratio - distance
                }
            };
            if (sqrt_ratio_limit < min) {
                sqrt_ratio_limit = min;
            }
            if (sqrt_ratio_limit > max) {
                sqrt_ratio_limit = max;
            }
            sqrt_ratio_limit
        }


        fn _swap_token_for_usdc(
            ref self: ContractState, sell_token: PAYMENT_TOKEN, sell_token_amount: u256,
        ) {
            let usdc_address = MainnetConfig::USDC_ADDRESS.try_into().unwrap();
            let pool_key = match sell_token {
                PAYMENT_TOKEN::STRK => PoolKey {
                    token0: usdc_address,
                    token1: MainnetConfig::STRK_ADDRESS.try_into().unwrap(),
                    fee: MainnetConfig::STARK_USDC_POOL_KEY,
                    tick_spacing: MainnetConfig::STARK_USDC_TICK_SPACING,
                    extension: 0x00.try_into().unwrap(),
                },
                PAYMENT_TOKEN::USDC_BRIDGED => PoolKey {
                    token0: usdc_address,
                    token1: MainnetConfig::USDC_BRIDGED_ADDRESS.try_into().unwrap(),
                    fee: MainnetConfig::USDC_BRIDGED_FEE,
                    tick_spacing: MainnetConfig::USDC_BRIDGED_TICK_SPACING,
                    extension: 0x00.try_into().unwrap(),
                },
                PAYMENT_TOKEN::USDT => PoolKey {
                    token0: usdc_address,
                    token1: MainnetConfig::USDT_ADDRESS.try_into().unwrap(),
                    fee: MainnetConfig::USDT_USDC_POOL_KEY,
                    tick_spacing: MainnetConfig::USDT_USDC_TICK_SPACING,
                    extension: 0x00.try_into().unwrap(),
                }
            };

            // This number was obteined through testing, its emprical
            let mut sqrt_ratio_distance = 184467484371483390610000000000000000;
            if sell_token == PAYMENT_TOKEN::STRK {
                sqrt_ratio_distance = 10000984467484371483390610000000000000000;
            }
            let callback = SwapAfterLockParameters {
                contract_address: self.ekubo.read().contract_address,
                to: get_contract_address(),
                sell_token_address: pool_key.token1,
                sell_token_amount,
                buy_token_address: usdc_address,
                pool_key,
                sqrt_ratio_distance,
            };

            let mut data: Array<felt252> = ArrayTrait::new();
            Serde::<SwapAfterLockParameters>::serialize(@callback, ref data);

            // Lock
            let ekubo = self.ekubo.read();
            ekubo.lock(data.span());
        }
    }
}
