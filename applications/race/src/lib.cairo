use starknet::{ContractAddress, get_caller_address, get_block_timestamp, get_contract_address};

// #[starknet::interface]
// pub trait IERC20<TContractState> {
//     fn get_name(self: @TContractState) -> felt252;
//     fn get_symbol(self: @TContractState) -> felt252;
//     fn get_decimals(self: @TContractState) -> u8;
//     fn get_total_supply(self: @TContractState) -> felt252;
//     fn balance_of(self: @TContractState, account: ContractAddress) -> felt252;
//     fn allowance(
//         self: @TContractState, owner: ContractAddress, spender: ContractAddress,
//     ) -> felt252;
//     fn transfer(ref self: TContractState, recipient: ContractAddress, amount: felt252);
//     fn transfer_from(
//         ref self: TContractState,
//         sender: ContractAddress,
//         recipient: ContractAddress,
//         amount: felt252,
//     );
//     fn approve(ref self: TContractState, spender: ContractAddress, amount: felt252);
//     fn increase_allowance(ref self: TContractState, spender: ContractAddress, added_value: felt252);
//     fn decrease_allowance(
//         ref self: TContractState, spender: ContractAddress, subtracted_value: felt252,
//     );
// }


#[derive(Drop, Copy, Serde, starknet::Store, PartialEq)]
#[allow(starknet::store_no_default_variant)]
pub enum GameStatus {
    NotStarted,
    OpenForJoin,
    InProgress,
    Completed,
}

#[derive(Drop, Copy, Serde, starknet::Store)]
pub struct Game {
    pub id: u32,
    pub start_time: u64,
    pub join_end_time: u64,
    pub status: GameStatus,
    pub total_drones: u32,
    pub total_deposits: u256,
    pub protocol_fee: u256,
    pub fee_percentage: u256,
    pub first_place: u32,
    pub second_place: u32,
    pub third_place: u32,
}

#[derive(Drop, Copy, Serde, starknet::Store)]
pub struct Bet {
    pub amount: u256,
    pub drone_id: u32,
}

#[starknet::interface]
pub trait IGameContract<TContractState> {
    fn create_game(ref self: TContractState, total_drones: u32, fee_percentage: u256) -> u32;
    fn place_bet(ref self: TContractState, game_id: u32, drone_id: u32, amount: u256);
    fn update_game_result(ref self: TContractState, game_id: u32, first: u32, second: u32, third: u32);
    fn get_game(self: @TContractState, game_id: u32) -> Game;
    fn get_user_bet(
        self: @TContractState, 
        game_id: u32, 
        player: ContractAddress, 
        drone_id: u32
    ) -> Bet;
    fn get_drone_total_bets(
        self: @TContractState,
        game_id: u32,
        drone_id: u32
    ) -> u256;
    fn get_undistributed_rewards(self: @TContractState, game_id: u32) -> u256;
    fn withdraw_undistributed(ref self: TContractState, game_id: u32, recipient: ContractAddress);
}

#[starknet::contract]
mod GameContract {
    use super::{Game, GameStatus, Bet, IGameContract};
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};

    // use erc20::token::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::{ContractAddress, get_caller_address, get_block_timestamp, get_contract_address};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };

    const MAX_DRONES: u32 = 12;
    const MIN_BET: u256 = 1000000000000000000; // 1 STRK
    const MAX_BET: u256 = 100000000000000000000; // 100 STRK
    const BETTING_WINDOW: u64 = 30;
    const FIRST_PLACE_PERCENTAGE: u256 = 50;  // 50% of remaining pool
    const SECOND_PLACE_PERCENTAGE: u256 = 30; // 30% of remaining pool
    const THIRD_PLACE_PERCENTAGE: u256 = 15;  // 15% of remaining pool

    // For precision in calculations
    const BASE_MULTIPLIER: u256 = 1_000;     

    // Maximum win multipliers - reduced for sustainability
    pub const MAX_WIN_MULTIPLIER_TOP1: u256 = 3_500; // Maximum 3.5x for first place
    pub const MAX_WIN_MULTIPLIER_TOP2: u256 = 2_500; // Maximum 2.5x for second place
    pub const MAX_WIN_MULTIPLIER_TOP3: u256 = 1_500; // Maximum 1.5x for third place

    #[storage]
    struct Storage {
        admin: ContractAddress,
        token: ContractAddress,
        games: Map<u32, Game>,
        next_game_id: u32,
        user_bets: Map<(u32, ContractAddress, u32), Bet>,
        drone_total_bets: Map<(u32, u32), u256>,
        user_drone_count: Map<(u32, ContractAddress), u32>,
        drone_user_count: Map<(u32, u32), u32>,
        drone_users: Map<(u32, u32, u32), ContractAddress>,
        undistributed_rewards: Map<u32, u256>,
    }

    #[constructor]
    fn constructor(ref self: ContractState, admin: ContractAddress, token: ContractAddress) {
        self.admin.write(admin);
        // self.token.write(token);
        self.token.write(token);
        self.next_game_id.write(0);
    }

    #[abi(embed_v0)]
    impl GameContractImpl of super::IGameContract<ContractState> {
        fn create_game(
            ref self: ContractState,
            total_drones: u32,
            fee_percentage: u256,
        ) -> u32 {
            assert(get_caller_address() == self.admin.read(), 'Not admin');
            assert(total_drones >= 3 && total_drones <= MAX_DRONES, 'Invalid drone count');
            assert(fee_percentage <= 5, 'Max fee is 5%');
            
            let game_id = self.next_game_id.read();
            let new_game = Game {
                id: game_id,
                start_time: get_block_timestamp(),
                join_end_time: get_block_timestamp() + BETTING_WINDOW,
                status: GameStatus::OpenForJoin,
                total_drones: total_drones,
                total_deposits: 0,
                protocol_fee: 0,
                fee_percentage: fee_percentage,
                first_place: 0,
                second_place: 0,
                third_place: 0,
            };

            self.games.write(game_id, new_game);
            self.next_game_id.write(game_id + 1);
            game_id
        }

        fn place_bet(
            ref self: ContractState, 
            game_id: u32, 
            drone_id: u32, 
            amount: u256
        ) {
            let mut game = self.games.read(game_id);
            // let current_time = get_block_timestamp();
            let player = get_caller_address();
            
            // Validations
            assert(game.status == GameStatus::OpenForJoin, 'Game not open for betting');
            // assert(current_time <= game.join_end_time, 'Betting window closed');
            assert(drone_id < game.total_drones, 'Invalid drone ID');
            assert(amount >= MIN_BET, 'Bet too small');
            assert(amount <= MAX_BET, 'Bet too large');

            // Transfer tokens from player
            let token = IERC20Dispatcher { contract_address: self.token.read() };
            let allowance = token.allowance(get_caller_address(), get_contract_address());
            let allowance_u256: u256 = allowance.into();
            assert(allowance_u256 >= amount, 'Insufficient allowance');

            let is_transfer_success = token.transfer_from(
                get_caller_address(),
                get_contract_address(),
                amount
            );
            assert(is_transfer_success, 'Transfer failed');

            // Update or create bet
            let existing_bet = self.user_bets.read((game_id, player, drone_id));
            let new_amount = existing_bet.amount + amount;
            let bet = Bet { amount: new_amount, drone_id };
            let is_first_bet = existing_bet.amount == 0;
            self.user_bets.write((game_id, player, drone_id), bet);

            // Track unique drone IDs if this is first bet on this drone
            if is_first_bet {
                let mut user_drones = self.user_drone_count.read((game_id, player));
                user_drones += 1;
                self.user_drone_count.write((game_id, player), user_drones);

                // Add user to drone's users list
                let mut drone_users = self.drone_user_count.read((game_id, drone_id));
                self.drone_users.write((game_id, drone_id, drone_users), player);
                drone_users += 1;
                self.drone_user_count.write((game_id, drone_id), drone_users);
            }

            // Update totals
            let current_drone_total = self.drone_total_bets.read((game_id, drone_id));
            self.drone_total_bets.write((game_id, drone_id), current_drone_total + amount);
            game.total_deposits += amount;
            self.games.write(game_id, game);
        }

        fn update_game_result(
            ref self: ContractState,
            game_id: u32,
            first: u32,
            second: u32,
            third: u32,
        ) {
            assert(get_caller_address() == self.admin.read(), 'Not admin');
            
            let mut game = self.games.read(game_id);
            assert(game.status == GameStatus::OpenForJoin, 'Invalid game status');
            assert(first < game.total_drones, 'Invalid first place');
            assert(second < game.total_drones, 'Invalid second place');
            assert(third < game.total_drones, 'Invalid third place');
            assert(first != second && first != third && second != third, 'Duplicate winners');

            // Calculate protocol fee first
            let protocol_fee = if game.total_deposits > 0 {
                (game.total_deposits * game.fee_percentage) / 100
            } else {
                0
            };

            // Ensure we have enough balance for fee
            assert(game.total_deposits >= protocol_fee, 'Insufficient balance for fee');

            // Calculate remaining pool safely
            let remaining_pool = game.total_deposits - protocol_fee;
            assert(remaining_pool <= game.total_deposits, 'Pool calculation overflow');

            // Update game state before transfers
            game.status = GameStatus::Completed;
            game.protocol_fee = protocol_fee;
            game.first_place = first;
            game.second_place = second;
            game.third_place = third;
            self.games.write(game_id, game);

            // Only transfer protocol fee if it's greater than 0
            if protocol_fee > 0 {
                let token = IERC20Dispatcher { contract_address: self.token.read() };
                token.transfer(self.admin.read(), protocol_fee.try_into().unwrap());
            }

            // Calculate prize pools safely
            let first_pool = if remaining_pool > 0 {
                (remaining_pool * FIRST_PLACE_PERCENTAGE) / 100
            } else {
                0
            };

            let second_pool = if remaining_pool > 0 {
                (remaining_pool * SECOND_PLACE_PERCENTAGE) / 100
            } else {
                0
            };

            let third_pool = if remaining_pool > 0 {
                (remaining_pool * THIRD_PLACE_PERCENTAGE) / 100
            } else {
                0
            };

            // Distribute rewards only if there are bets
            let first_total_bets = self.drone_total_bets.read((game_id, first));
            if first_total_bets > 0 && first_pool > 0 {
                self.distribute_rewards(game_id, first, first_pool);
            }

            let second_total_bets = self.drone_total_bets.read((game_id, second));
            if second_total_bets > 0 && second_pool > 0 {
                self.distribute_rewards(game_id, second, second_pool);
            }

            let third_total_bets = self.drone_total_bets.read((game_id, third));
            if third_total_bets > 0 && third_pool > 0 {
                self.distribute_rewards(game_id, third, third_pool);
            }

            // Store any undistributed rewards
            let total_distributed = first_pool + second_pool + third_pool;
            let undistributed = remaining_pool - total_distributed;
            if undistributed > 0 {
                self.undistributed_rewards.write(game_id, undistributed);
            }
        }

        fn get_game(self: @ContractState, game_id: u32) -> Game {
            self.games.read(game_id)
        }

        fn get_user_bet(
            self: @ContractState,
            game_id: u32,
            player: ContractAddress,
            drone_id: u32
        ) -> Bet {
            self.user_bets.read((game_id, player, drone_id))
        }

        fn get_drone_total_bets(
            self: @ContractState,
            game_id: u32,
            drone_id: u32
        ) -> u256 {
            self.drone_total_bets.read((game_id, drone_id))
        }

        fn get_undistributed_rewards(self: @ContractState, game_id: u32) -> u256 {
            self.undistributed_rewards.read(game_id)
        }

        fn withdraw_undistributed(
            ref self: ContractState,
            game_id: u32,
            recipient: ContractAddress
        ) {
            // Only admin can withdraw
            assert(get_caller_address() == self.admin.read(), 'Not admin');
            
            // Get undistributed amount
            let undistributed = self.undistributed_rewards.read(game_id);
            assert(undistributed > 0, 'No undistributed rewards');
            
            // Reset undistributed amount
            self.undistributed_rewards.write(game_id, 0);
            
            // Transfer to recipient
            let token = IERC20Dispatcher { contract_address: self.token.read() };
            token.transfer(recipient, undistributed);
        }
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn distribute_rewards(
            ref self: ContractState,
            game_id: u32,
            drone_id: u32,
            pool: u256
        ) {
            let token = IERC20Dispatcher { contract_address: self.token.read() };
            let total_drone_bets = self.drone_total_bets.read((game_id, drone_id));
            let total_users = self.drone_user_count.read((game_id, drone_id));
            let game = self.games.read(game_id);

            // Get max multiplier based on position
            let max_multiplier = if drone_id == game.first_place {
                MAX_WIN_MULTIPLIER_TOP1
            } else if drone_id == game.second_place {
                MAX_WIN_MULTIPLIER_TOP2
            } else {
                MAX_WIN_MULTIPLIER_TOP3
            };

            let mut total_undistributed: u256 = 0;
            let mut i: u32 = 0;
            loop {
                if i >= total_users {
                    break;
                }
                
                let user = self.drone_users.read((game_id, drone_id, i));
                let bet = self.user_bets.read((game_id, user, drone_id));
                
                if bet.amount > 0 {
                    let reward = (pool * bet.amount) / total_drone_bets;
                    let max_win = (bet.amount * (max_multiplier - BASE_MULTIPLIER)) / BASE_MULTIPLIER;
                    
                    let final_reward = if reward > max_win {
                        max_win
                    } else {
                        reward
                    };
                    
                    // Track undistributed amount
                    if reward > max_win {
                        total_undistributed += (reward - max_win);
                    }
                    
                    if final_reward > 0 {
                        let return_amount = bet.amount + final_reward;
                        token.transfer(user, return_amount);
                    }
                }
                
                i += 1;
            };

            // Store undistributed amount for this game
            let current_undistributed = self.undistributed_rewards.read(game_id);
            self.undistributed_rewards.write(game_id, current_undistributed + total_undistributed);
        }
    }
}


#[cfg(test)]
mod tests {
    use starknet::{ContractAddress, syscalls::deploy_syscall, contract_address_const,class_hash_const, ClassHash, contract_address_to_felt252};
    use snforge_std::{
        declare, start_cheat_caller_address, stop_cheat_caller_address, spy_events,
        EventSpyAssertionsTrait, DeclareResultTrait, ContractClassTrait,
    };
    use core::result::ResultTrait;
    use core::traits::Into;
    use race::{
        GameContract,
        IGameContractDispatcher, 
        IGameContractDispatcherTrait,
        GameStatus,
        Game,
        Bet
    };

    use erc20::token::{IERC20Dispatcher, IERC20DispatcherTrait};

    const ADMIN: felt252 = 0x123;
    const PLAYER: felt252 = 0x456;
    const PLAYER1: felt252 = 0x457;
    const PLAYER2: felt252 = 0x789;
    const PLAYER3: felt252 = 0xabc;
    const PLAYER4: felt252 = 0xdef;
    const PLAYER5: felt252 = 0x111;

    const token_name: felt252 = 'starknet';
    const decimals: u8 = 18;
    const initial_supply: felt252 = 100000;
    const symbols: felt252 = 'STRK';

    fn format_balance(balance: felt252) -> (felt252, felt252) {
        let balance_u256: u256 = balance.into();
        let divisor: u256 = 1_000_000_000_000_000_000_u256;
        let whole: felt252 = (balance_u256 / divisor).try_into().unwrap();
        let decimal: felt252 = (balance_u256 % divisor).try_into().unwrap();
        (whole, decimal)
    }

    pub fn deploy_contract() -> (IGameContractDispatcher, ContractAddress, IERC20Dispatcher, ContractAddress) {
        // deploy mock ETH token
        let erc20_contract = declare("erc20").unwrap().contract_class();

        let mut token_calldata = array![];
        let deployer = contract_address_const::<'caller'>();
        (deployer, token_name, decimals, initial_supply,symbols).serialize(ref token_calldata);
        let token_address = erc20_contract.precalculate_address(@token_calldata);
        start_cheat_caller_address(token_address, deployer);
        erc20_contract.deploy(@token_calldata).unwrap();
        stop_cheat_caller_address(token_address);
        

        let loyalty_race_contract = declare("GameContract").unwrap().contract_class();

        // let loyalty_race_contract = declare("LoyaltyRace").unwrap().contract_class();
        let mut loyalty_race_calldata: Array<felt252> = array![];
        (contract_address_const::<ADMIN>(), token_address).serialize(ref loyalty_race_calldata);
        loyalty_race_contract.deploy(@loyalty_race_calldata).unwrap();
        let loyalty_race_address = loyalty_race_contract.precalculate_address(@loyalty_race_calldata);
        start_cheat_caller_address(loyalty_race_address, deployer);
        loyalty_race_contract.deploy(@loyalty_race_calldata).unwrap();
        stop_cheat_caller_address(loyalty_race_address);
        // let (loyalty_race_contract_address, _) = loyalty_race_contract.deploy(@calldata).unwrap();


        let token_dispatcher = IERC20Dispatcher { contract_address: token_address };
        let loyalty_race_dispatcher = IGameContractDispatcher { contract_address: loyalty_race_address };
        // (loyalty_race_dispatcher, eth_dispatcher)

        (loyalty_race_dispatcher, loyalty_race_address, token_dispatcher, token_address)
    }
        
    // #[test]
    // fn test_create_game() {
    //     let deployer = contract_address_const::<'caller'>();
    //     let (race_contract_dispatcher, race_contract_address, token_dispatcher, token_address) = deploy_contract();
    //     let balance = token_dispatcher.balance_of(deployer);
    //     println!("balance: {}", balance);
    //     println!("race_contract_address: {}", contract_address_to_felt252(race_contract_address));
    //     println!("token_address: {}", contract_address_to_felt252(token_address));

    //     let admin = contract_address_const::<ADMIN>();

    //     start_cheat_caller_address(race_contract_address, admin); // admin caller
    //     let game_id = race_contract_dispatcher.create_game(5, 3); // create game with 5 drones and 3% fee
    //     stop_cheat_caller_address(race_contract_address); // stop admin caller

    //     let game = race_contract_dispatcher.get_game(game_id);

    //     assert(game.total_drones == 5, 'Invalid drone count');
    //     assert(game.fee_percentage == 3, 'Invalid fee percentage');
    //     assert(game.status == GameStatus::OpenForJoin, 'Invalid status');
    //     assert(game.status != GameStatus::InProgress, 'Invalid status');
    //     assert(game.status != GameStatus::Completed, 'Invalid status');
    // }    

    // #[test]
    // fn test_place_bet() {
    //     let (race_contract, race_address, token, token_address) = deploy_contract();
    //     let admin = contract_address_const::<ADMIN>();
    //     let player = contract_address_const::<PLAYER>();
        
    //     // Create game as admin
    //     start_cheat_caller_address(race_address, admin);
    //     let game_id = race_contract.create_game(5, 3);
    //     stop_cheat_caller_address(race_address);

    //     // Give player some tokens and approve spending
    //     start_cheat_caller_address(token_address, admin);
    //     token.transfer(player, 10_000000000000000000); // 10 STRK
    //     stop_cheat_caller_address(token_address);

    //     start_cheat_caller_address(token_address, player);
    //     token.approve(race_address, 10_000000000000000000);
    //     stop_cheat_caller_address(token_address);

    //     // Place bet as player
    //     start_cheat_caller_address(race_address, player);
    //     race_contract.place_bet(game_id, 1, 2_000000000000000000); // 2 STRK bet on drone 1
    //     stop_cheat_caller_address(race_address);

    //     // Check game state
    //     let game = race_contract.get_game(game_id);
    //     assert(game.total_deposits == 2_000000000000000000, 'Invalid total deposits');
    // }

    // #[test]
    // fn test_update_game_result() {
    //     let (race_contract, race_address, token, token_address) = deploy_contract();
    //     let admin = contract_address_const::<ADMIN>();
    //     let player = contract_address_const::<PLAYER>();
        
    //     // Create game and place bet
    //     start_cheat_caller_address(race_address, admin);
    //     let game_id = race_contract.create_game(5, 10); // 10% fee
    //     stop_cheat_caller_address(race_address);

    //     // Give player tokens and approve
    //     start_cheat_caller_address(token_address, admin);
    //     token.transfer(player, 10_000000000000000000);
    //     stop_cheat_caller_address(token_address);

    //     start_cheat_caller_address(token_address, player);
    //     token.approve(race_address, 10_000000000000000000);
    //     stop_cheat_caller_address(token_address);

    //     // Place bet
    //     start_cheat_caller_address(race_address, player);
    //     race_contract.place_bet(game_id, 1, 5_000000000000000000); // 5 STRK on winning drone
    //     stop_cheat_caller_address(race_address);

    //     // Get admin balance before closing game
    //     let initial_admin_balance: felt252 = token.balance_of(admin);

    //     // Close the game
    //     start_cheat_caller_address(race_address, admin);
    //     race_contract.update_game_result(game_id, 0, 1, 2); // Set winners
    //     stop_cheat_caller_address(race_address);

    //     // Check admin fee after game is closed and log balances
    //     let admin_balance: felt252 = token.balance_of(admin);
    //     let expected_fee: felt252 = (500000000000000000).try_into().unwrap(); // 10% of 5 STRK
    //     assert(admin_balance == initial_admin_balance + expected_fee, 'Wrong admin fee');
    //     println!("Admin final balance: {}", admin_balance);
    //     println!("Admin fee collected: {}", expected_fee);

    //     // Check and log player rewards
    //     let final_game = race_contract.get_game(game_id);
    //     let final_admin_balance: felt252 = token.balance_of(admin);
    //     let final_player_balance: felt252 = token.balance_of(player);
    //     let balance_change: felt252 = final_player_balance - initial_admin_balance;
        
    //     println!("Player - Initial: {}, Final: {}, Change: {}", 
    //         initial_admin_balance, 
    //         final_player_balance,
    //         balance_change
    //     );
        
    //     assert(final_player_balance != 0, 'Player balance should not be 0');
    //     assert(final_admin_balance == initial_admin_balance + expected_fee, 'Wrong admin fee');
    //     assert(final_game.status == GameStatus::Completed, 'Game not completed');
    //     assert(final_game.first_place == 0, 'Wrong first place');
    //     assert(final_game.second_place == 1, 'Wrong second place');
    //     assert(final_game.third_place == 2, 'Wrong third place');
    //     let expected_fee_u256: u256 = expected_fee.into();
    //     assert(final_game.protocol_fee == expected_fee_u256, 'Wrong protocol fee');

    //     // Game Summary
    //     let (pool_whole, pool_decimal) = format_balance(final_game.total_deposits.try_into().unwrap());
    //     let (fee_whole, fee_decimal) = format_balance(final_game.protocol_fee.try_into().unwrap());
    //     println!("\nGame Summary:");
    //     println!("Total Pool: {}.{} STRK", pool_whole, pool_decimal);
    //     println!("Protocol Fee: {}.{} STRK", fee_whole, fee_decimal);

    //     // Show total bets per drone
    //     println!("\nTotal bets per drone:");
    //     let mut drone_id: u32 = 0;
    //     loop {
    //         if drone_id >= 8 {
    //             break;
    //         }
    //         let drone_bets = race_contract.get_drone_total_bets(game_id, drone_id);
    //         if drone_bets > 0 {
    //             let (bet_whole, bet_decimal) = format_balance(drone_bets.try_into().unwrap());
    //             if drone_id == final_game.first_place {
    //                 println!("Drone {} (1st): {}.{} STRK", drone_id, bet_whole, bet_decimal);
    //             } else if drone_id == final_game.second_place {
    //                 println!("Drone {} (2nd): {}.{} STRK", drone_id, bet_whole, bet_decimal);
    //             } else if drone_id == final_game.third_place {
    //                 println!("Drone {} (3rd): {}.{} STRK", drone_id, bet_whole, bet_decimal);
    //             } else {
    //                 println!("Drone {}: {}.{} STRK", drone_id, bet_whole, bet_decimal);
    //             }
    //         }
    //         drone_id += 1;
    //     };

    //     // Show admin balance
    //     let final_admin_balance = token.balance_of(admin);
    //     let initial_admin_balance = token.balance_of(admin) - final_game.protocol_fee.try_into().unwrap();
    //     let (init_whole, init_decimal) = format_balance(initial_admin_balance);
    //     let (final_whole, final_decimal) = format_balance(final_admin_balance);
    //     println!("\nAdmin balance:");
    //     println!("Initial: {}.{} STRK", init_whole, init_decimal);
    //     println!("Final: {}.{} STRK", final_whole, final_decimal);
    // }

    // #[test]
    // fn test_multiple_bets_on_different_drones() {
    //     let (race_contract, race_address, token, token_address) = deploy_contract();
    //     let admin = contract_address_const::<ADMIN>();
    //     let player = contract_address_const::<PLAYER>();

    //     // Setup game and tokens
    //     start_cheat_caller_address(race_address, admin);
    //     let game_id = race_contract.create_game(5, 3);
    //     stop_cheat_caller_address(race_address);

    //     start_cheat_caller_address(token_address, admin);
    //     token.transfer(player, 20_000000000000000000); // 20 STRK
    //     stop_cheat_caller_address(token_address);

    //     start_cheat_caller_address(token_address, player);
    //     token.approve(race_address, 20_000000000000000000);
    //     stop_cheat_caller_address(token_address);

    //     // Place bets on different drones
    //     start_cheat_caller_address(race_address, player);
    //     race_contract.place_bet(game_id, 0, 2_000000000000000000); // 2 STRK on drone 0
    //     race_contract.place_bet(game_id, 1, 3_000000000000000000); // 3 STRK on drone 1
    //     race_contract.place_bet(game_id, 2, 4_000000000000000000); // 4 STRK on drone 2
    //     stop_cheat_caller_address(race_address);

    //     // Check game state
    //     let game = race_contract.get_game(game_id);
    //     assert(game.total_deposits == 9_000000000000000000, 'Invalid total deposits');
    // }

    // #[test]
    // fn test_multiple_bets_on_same_drone() {
    //     let (race_contract, race_address, token, token_address) = deploy_contract();
    //     let admin = contract_address_const::<ADMIN>();
    //     let player = contract_address_const::<PLAYER>();

    //     // Setup game and tokens
    //     start_cheat_caller_address(race_address, admin);
    //     let game_id = race_contract.create_game(5, 3);
    //     stop_cheat_caller_address(race_address);

    //     start_cheat_caller_address(token_address, admin);
    //     token.transfer(player, 20_000000000000000000); // 20 STRK
    //     stop_cheat_caller_address(token_address);

    //     start_cheat_caller_address(token_address, player);
    //     token.approve(race_address, 20_000000000000000000);
    //     stop_cheat_caller_address(token_address);

    //     // Place multiple bets on same drone
    //     start_cheat_caller_address(race_address, player);
    //     race_contract.place_bet(game_id, 1, 2_000000000000000000); // 2 STRK on drone 1
    //     race_contract.place_bet(game_id, 1, 3_000000000000000000); // 3 more STRK on drone 1
    //     stop_cheat_caller_address(race_address);

    //     // Check game state
    //     let game = race_contract.get_game(game_id);
    //     assert(game.total_deposits == 5_000000000000000000, 'Invalid total deposits');
    // }

   #[test]
    fn test_full_game_flow() {
        let (race_contract, race_address, token, token_address) = deploy_contract();
        let admin = contract_address_const::<ADMIN>();

        // Give admin initial tokens
        let deployer = contract_address_const::<'caller'>();
        start_cheat_caller_address(token_address, deployer);
        token.transfer(admin, 1000_000000000000000000); // Give 1000 STRK to admin
        stop_cheat_caller_address(token_address);

        // Store initial admin balance
        let initial_admin_balance = token.balance_of(admin);
        assert(initial_admin_balance == 1000_000000000000000000, 'Wrong initial admin balance');

        let (deployer_balance, deployer_decimal) = format_balance(token.balance_of(deployer));
        println!("=> Deployer balance: {}.{} STRK", deployer_balance, deployer_decimal);
        
        let (admin_whole, admin_decimal) = format_balance(initial_admin_balance);
        println!("=> Admin initial balance: {}.{} STRK", admin_whole, admin_decimal);

        // Create game with 8 drones and 3% fee
        start_cheat_caller_address(race_address, admin);
        let game_id = race_contract.create_game(8, 5);
        stop_cheat_caller_address(race_address);

        // Verify admin balance hasn't changed after creating game
        let post_create_balance = token.balance_of(admin);
        assert(post_create_balance == initial_admin_balance, 'AD balance changed unexpectedly');
        
        let (admin_whole, admin_decimal) = format_balance(post_create_balance);
        println!("Admin balance after create game: {}.{} STRK", admin_whole, admin_decimal);

        // Setup 22 players with fixed addresses
        let mut players: Array<ContractAddress> = ArrayTrait::new();
        players.append(contract_address_const::<0x1234>());
        players.append(contract_address_const::<0x1235>());
        players.append(contract_address_const::<0x1236>());
        players.append(contract_address_const::<0x1237>());
        players.append(contract_address_const::<0x1238>());
        players.append(contract_address_const::<0x1239>());
        players.append(contract_address_const::<0x123A>());
        players.append(contract_address_const::<0x123B>());
        players.append(contract_address_const::<0x123C>());
        players.append(contract_address_const::<0x123D>());
        players.append(contract_address_const::<0x123E>());
        // players.append(contract_address_const::<0x123F>());
        // players.append(contract_address_const::<0x1240>());
        // players.append(contract_address_const::<0x1241>());
        // players.append(contract_address_const::<0x1242>());
        // players.append(contract_address_const::<0x1243>());
        // players.append(contract_address_const::<0x1244>());
        // players.append(contract_address_const::<0x1245>());
        // players.append(contract_address_const::<0x1246>());
        // players.append(contract_address_const::<0x1247>());
        // players.append(contract_address_const::<0x1248>());
        // players.append(contract_address_const::<0x1249>());

        // Log initial admin balance
        let (admin_whole, admin_decimal) = format_balance(token.balance_of(admin));
        println!("Admin initial balance: {}.{} STRK", admin_whole, admin_decimal);

    //     // Track balances at each stage for each player
        let mut player_balance_tracking: Array<(ContractAddress, felt252, felt252, felt252)> = ArrayTrait::new(); // (address, pre, after_bet, final)
        
        // Give each player initial tokens and track balances
        let mut i: u32 = 0;
        loop {
            if i >= players.len() {
                break;
            }
            let player = *players.at(i.try_into().unwrap());
            
            // Fund player with initial tokens
            start_cheat_caller_address(token_address, deployer);
            token.transfer(player, 1000_000000000000000000); // Give 1000 STRK to each player
            stop_cheat_caller_address(token_address);

            // Approve spending
            start_cheat_caller_address(token_address, player);
            token.approve(race_address, 1000_000000000000000000);
            stop_cheat_caller_address(token_address);

            // Store initial balance
            let initial_balance = token.balance_of(player);
            let (whole, decimal) = format_balance(initial_balance);
            println!("Player {} initial balance: {}.{} STRK", i, whole, decimal);
            player_balance_tracking.append((player, initial_balance, 0, 0));
            i += 1;
        };

        let (ls1, ls1_decimail) = format_balance(token.balance_of(admin));
        println!("=>Admin balance after fund: {}.{} STRK", ls1, ls1_decimail);

        // Place bets and track post-bet balances
        let mut i: u32 = 0;
        loop {
            if i >= players.len() {
                break;
            }
            let player = *players.at(i.try_into().unwrap());
            
            // Place bets
            let mut bet_count: u32 = 0;
            let max_bets = 2 + (i % 3);
            let mut player_total_bet: u256 = 0;
            
            loop {
                if bet_count >= max_bets {
                    break;
                }
                let bet_index_u32: u32 = (i + bet_count).try_into().unwrap();
                let drone_id: u32 = bet_index_u32 % 8_u32;
                let bet_base: u256 = (1_u32 + (bet_index_u32 % 10_u32)).into();
                let bet_amount: u256 = bet_base * 1_000_000_000_000_000_000_u256;
                
                start_cheat_caller_address(race_address, player);
                race_contract.place_bet(game_id, drone_id, bet_amount);
                stop_cheat_caller_address(race_address);
                player_total_bet += bet_amount;
                bet_count += 1;
            };

            // Store post-bet balance
            let post_bet_balance = token.balance_of(player);
            let (whole_balance, decimal_balance) = format_balance(post_bet_balance);
            let (whole_bet, decimal_bet) = format_balance(player_total_bet.try_into().unwrap());
            println!("Player {} after bets - Balance: {}.{} STRK, Total bet: {}.{} STRK", 
                i, whole_balance, decimal_balance, whole_bet, decimal_bet);
            
            // Update tracking array
            let mut new_tracking: Array<(ContractAddress, felt252, felt252, felt252)> = ArrayTrait::new();
            let mut j: u32 = 0;
            loop {
                if j >= player_balance_tracking.len() {
                    break;
                }
                let (addr, pre, _, _) = *player_balance_tracking.at(j.try_into().unwrap());
                if addr == player {
                    new_tracking.append((addr, pre, post_bet_balance, 0));
                } else {
                    new_tracking.append(*player_balance_tracking.at(j.try_into().unwrap()));
                }
                j += 1;
            };
            player_balance_tracking = new_tracking;
            i += 1;
        };

        // Log initial admin balance
        let (admin_whole, admin_decimal) = format_balance(token.balance_of(admin));
        println!("Admin balance after bets game: {}.{} STRK", admin_whole, admin_decimal);

        // Update game result and track final balances
        start_cheat_caller_address(race_address, admin);
        race_contract.update_game_result(game_id, 0, 1, 2);
        stop_cheat_caller_address(race_address);

        // Log update game result
        let (admin_whole, admin_decimal) = format_balance(token.balance_of(admin));
        println!("Admin balance after updated game: {}.{} STRK", admin_whole, admin_decimal);

        // // Log final results
        let final_game = race_contract.get_game(game_id);
        // let (admin_whole, admin_decimal) = format_balance(token.balance_of(admin));
        // let (fee_whole, fee_decimal) = format_balance(token.balance_of(admin) - initial_admin_balance);
        // println!("\nFinal Results:");
        // println!("Admin: Initial={}.{} STRK, Final={}.{} STRK, Fee={}.{} STRK", 
        //     admin_whole, admin_decimal,
        //     admin_whole, admin_decimal,
        //     fee_whole, fee_decimal
        // );

        // Log player results
        let mut i: u32 = 0;
        loop {
            if i >= players.len() {
                break;
            }
            let player = *players.at(i.try_into().unwrap());
            // let (initial_balance, post_bet, final_bal, _) = *player_balance_tracking.at(i.try_into().unwrap());
            let final_balance = token.balance_of(player);
            
            // println!("\nPlayer {} results:", i);
            let mut total_bet_amount: u256 = 0;
            // let mut total_earn_amount: u256 = 0;
            // let mut total_lost_amount: u256 = 0;
            
            // Show initial balance
            // let (init_whole, init_decimal) = format_balance(1000_000000000000000000_u256.try_into().unwrap());
            // println!("Initial:     {}.{} STRK", init_whole, init_decimal);
            
            // Check bets on each drone
            let mut drone_id: u32 = 0;
            // loop {
            //     if drone_id >= 8 {
            //         break;
            //     }
            //     let bet = race_contract.get_user_bet(game_id, player, drone_id);
            //     if bet.amount != 0 {
            //         let (amount_whole, amount_decimal) = format_balance(bet.amount.try_into().unwrap());
            //         total_bet_amount += bet.amount;
                    
            //         if drone_id == final_game.first_place {
            //             // Calculate share of first place pool (50% of remaining pool)
            //             let first_place_pool = (final_game.total_deposits - final_game.protocol_fee) * 50 / 100;
            //             let drone_total_bets = race_contract.get_drone_total_bets(game_id, drone_id);
            //             let reward = (bet.amount * first_place_pool) / drone_total_bets;
            //             total_earn_amount += reward;
            //             let (reward_whole, reward_decimal) = format_balance(reward.try_into().unwrap());
            //             println!("WIN on drone {}: Bet {}.{} STRK => Earned +{}.{} STRK (50% pool)", 
            //                 drone_id, amount_whole, amount_decimal,
            //                 reward_whole, reward_decimal
            //             );
            //         } else if drone_id == final_game.second_place {
            //             // Calculate share of second place pool (30% of remaining pool)
            //             let second_place_pool = (final_game.total_deposits - final_game.protocol_fee) * 30 / 100;
            //             let drone_total_bets = race_contract.get_drone_total_bets(game_id, drone_id);
            //             let reward = (bet.amount * second_place_pool) / drone_total_bets;
            //             total_earn_amount += reward;
            //             let (reward_whole, reward_decimal) = format_balance(reward.try_into().unwrap());
            //             println!("WIN on drone {}: Bet {}.{} STRK => Earned +{}.{} STRK (30% pool)", 
            //                 drone_id, amount_whole, amount_decimal,
            //                 reward_whole, reward_decimal
            //             );
            //         } else if drone_id == final_game.third_place {
            //             // Calculate share of third place pool (20% of remaining pool)
            //             let third_place_pool = (final_game.total_deposits - final_game.protocol_fee) * 20 / 100;
            //             let drone_total_bets = race_contract.get_drone_total_bets(game_id, drone_id);
            //             let reward = (bet.amount * third_place_pool) / drone_total_bets;
            //             total_earn_amount += reward;
            //             let (reward_whole, reward_decimal) = format_balance(reward.try_into().unwrap());
            //             println!("WIN on drone {}: Bet {}.{} STRK => Earned +{}.{} STRK (20% pool)", 
            //                 drone_id, amount_whole, amount_decimal,
            //                 reward_whole, reward_decimal
            //             );
            //         } else {
            //             total_lost_amount += bet.amount;
            //             println!("LOST on drone {}: -{}.{} STRK", drone_id, amount_whole, amount_decimal);
            //         }
            //     }
            //     drone_id += 1;
            // };
            
            // // Show summary
            // let (bet_whole, bet_decimal) = format_balance(total_bet_amount.try_into().unwrap());
            // let (earn_whole, earn_decimal) = format_balance(total_earn_amount.try_into().unwrap());
            // let (final_whole, final_decimal) = format_balance(final_balance);
            
            // // let initial_balance = 1000_000000000000000000_u256; // 1000 STRK
            // // let expected_balance = initial_balance + total_earn_amount - total_lost_amount;
            // // let (expected_whole, expected_decimal) = format_balance(expected_balance.try_into().unwrap());
            
            // println!("Total bet: {}.{} STRK", bet_whole, bet_decimal);
            // println!("Total earned: +{}.{} STRK", earn_whole, earn_decimal);
            // println!("Final balance: {}.{} STRK", final_whole, final_decimal);
            // let result_balance = token.balance_of(player);
            // let (result_whole, result_decimal) = format_balance(result_balance);
            // println!("Post bet balance: {}.{} STRK", result_whole, result_decimal);

            // println!("Post bet balance: {}.{} STRK", format_balance(result_balance));
            // println!("Expected balance: {}.{} STRK", expected_whole, expected_decimal);
            // assert(final_balance == expected_balance.try_into().unwrap(), 'Wrong final balance');

            println!("\nPlayer {} Balance Breakdown:", i);
            
            // Initial balance and total bets
            let (init_whole, init_decimal) = format_balance(1000_000000000000000000_u256.try_into().unwrap());
            println!("  Initial:     {}.{} STRK", init_whole, init_decimal);
            let (bet_whole, bet_decimal) = format_balance(total_bet_amount.try_into().unwrap());
            println!("  Bets:        -{}.{} STRK", bet_whole, bet_decimal);
            let (after_whole, after_decimal) = format_balance((1000_000000000000000000_u256 - total_bet_amount).try_into().unwrap());
            println!("  After bets:   {}.{} STRK", after_whole, after_decimal);

             // Show winning bets returned
            println!("\n    Winning bets returned:");
            drone_id = 0;
            loop {
                if drone_id >= 8 {
                    break;
                }
                let bet = race_contract.get_user_bet(game_id, player, drone_id);
                if bet.amount > 0 {
                    if drone_id == final_game.first_place || 
                       drone_id == final_game.second_place || 
                       drone_id == final_game.third_place {
                        let (bet_whole, bet_decimal) = format_balance(bet.amount.try_into().unwrap());
                        println!("      - Drone {}:     +{}.{} STRK (original bet)", drone_id, bet_whole, bet_decimal);
                    } else {
                        let (bet_whole, bet_decimal) = format_balance(bet.amount.try_into().unwrap());
                        println!("      - Lost bet:      -{}.{} STRK (drone {})", bet_whole, bet_decimal, drone_id);
                    }
                }
                drone_id += 1;
            };

             // Show extra winnings
            println!("\n    Extra winnings:");
            drone_id = 0;
            loop {
                if drone_id >= 8 {
                    break;
                }
                let bet = race_contract.get_user_bet(game_id, player, drone_id);
                if bet.amount > 0 {
                    if drone_id == final_game.first_place {
                        let first_pool = (final_game.total_deposits - final_game.protocol_fee) * 50 / 100;
                        let drone_total_bets = race_contract.get_drone_total_bets(game_id, drone_id);
                        let reward = (bet.amount * first_pool) / drone_total_bets;
                        let (reward_whole, reward_decimal) = format_balance(reward.try_into().unwrap());
                        println!("      - Drone {}:     +{}.{} STRK", drone_id, reward_whole, reward_decimal);
                    } else if drone_id == final_game.second_place {
                        let second_pool = (final_game.total_deposits - final_game.protocol_fee) * 30 / 100;
                        let drone_total_bets = race_contract.get_drone_total_bets(game_id, drone_id);
                        let reward = (bet.amount * second_pool) / drone_total_bets;
                        let (reward_whole, reward_decimal) = format_balance(reward.try_into().unwrap());
                        println!("      - Drone {}:     +{}.{} STRK", drone_id, reward_whole, reward_decimal);
                    } else if drone_id == final_game.third_place {
                        let third_pool = (final_game.total_deposits - final_game.protocol_fee) * 20 / 100;
                        let drone_total_bets = race_contract.get_drone_total_bets(game_id, drone_id);
                        let reward = (bet.amount * third_pool) / drone_total_bets;
                        let (reward_whole, reward_decimal) = format_balance(reward.try_into().unwrap());
                        println!("      - Drone {}:     +{}.{} STRK", drone_id, reward_whole, reward_decimal);
                    }
                }
                drone_id += 1;
            };

            // Show final balance
            let (final_whole, final_decimal) = format_balance(final_balance);
            println!("\n    Final:       {}.{} STRK", final_whole, final_decimal);
            
            i += 1;
        };

        // Log undistributed rewards
        let undistributed_rewards = race_contract.get_undistributed_rewards(game_id);
        let (undist_whole, undist_decimal) = format_balance(undistributed_rewards.try_into().unwrap());
        println!("\n=== Pool Distribution ===");
        
        // Calculate and log total pool and remaining pool
        let total_pool = final_game.total_deposits;
        let remaining_pool = total_pool - final_game.protocol_fee;
        let (total_whole, total_decimal) = format_balance(total_pool.try_into().unwrap());
        let (remain_whole, remain_decimal) = format_balance(remaining_pool.try_into().unwrap());
        
        println!("Total pool: {}.{} STRK", total_whole, total_decimal);
        println!("Remaining pool: {}.{} STRK", remain_whole, remain_decimal);
        println!("Undistributed rewards: {}.{} STRK", undist_whole, undist_decimal);

        // Log pool distribution details
        println!("\n=== Pool Distribution Details ===");
        
        // Total pool and protocol fee
        let total_pool = final_game.total_deposits;
        let protocol_fee = final_game.protocol_fee;
        let remaining_pool = total_pool - protocol_fee;
        
        let (total_whole, total_decimal) = format_balance(total_pool.try_into().unwrap());
        let (fee_whole, fee_decimal) = format_balance(protocol_fee.try_into().unwrap());
        let (remain_whole, remain_decimal) = format_balance(remaining_pool.try_into().unwrap());
        
        println!("Total pool: {}.{} STRK", total_whole, total_decimal);
        println!("Protocol fee (3%): {}.{} STRK", fee_whole, fee_decimal);
        println!("Remaining pool: {}.{} STRK", remain_whole, remain_decimal);
        
        // Prize pools
        let first_pool = (remaining_pool * 50) / 100;
        let second_pool = (remaining_pool * 30) / 100;
        let third_pool = (remaining_pool * 20) / 100;
        
        println!("\nPrize Distribution:");
        let (first_whole, first_decimal) = format_balance(first_pool.try_into().unwrap());
        let (second_whole, second_decimal) = format_balance(second_pool.try_into().unwrap());
        let (third_whole, third_decimal) = format_balance(third_pool.try_into().unwrap());
        println!("1st place (Drone 0): {}.{} STRK (50%)", first_whole, first_decimal);
        println!("2nd place (Drone 1): {}.{} STRK (30%)", second_whole, second_decimal);
        println!("3rd place (Drone 2): {}.{} STRK (20%)", third_whole, third_decimal);
        
        // Undistributed rewards
        let undistributed = race_contract.get_undistributed_rewards(game_id);
        let (undist_whole, undist_decimal) = format_balance(undistributed.try_into().unwrap());
        println!("\nUndistributed rewards: {}.{} STRK", undist_whole, undist_decimal);
        
        // Actually distributed
        let distributed = remaining_pool - undistributed;
        let (dist_whole, dist_decimal) = format_balance(distributed.try_into().unwrap());
        println!("Actually distributed: {}.{} STRK", dist_whole, dist_decimal);
    }
}