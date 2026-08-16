The goal of this project is quite unique, I want to automate the process of spawning X amount of bots, and populating a battleground with them. But i want more functionality than just that, I want to create multiple rosters that i will treat as teams, and use these teams to create a tournament, where various teams will compete, and the winners will advance through the tournament bracket.

think of it like march madness, but with AI player bots instead of baskbetball. I want this to be viewed as a sporting event, allowing viewers to cheer on their favorite team and team members as they watch this tournament progress

The project will first start of with automating this whole process within the WSG battleground, and then will expand to the other battlegrounds once the overall framework and idea are working within WSG

Due to the nature of the skills that we have access to us with the private server, I want the teams to spawn with proper food, gear, and potions that we'd expect a level 60 player to have in classic wow.

On top of creating various teams with gear for the tournament, i want to implement a way for viewers of the tournament to interact with the bots that are playing.
I have seen streams on tiktok and twitch where the chat input and donations to the stream, directly affect the game that is being streamed
Ideas for this that i have are:
1. Healing a specific player on a team
2. Healing an entire team
3. Killing a player on a team
4. Killing an entire team
5. Upgrading the armor of a player on the team
6. Upgrading the armor of a whole team
7. Upgrading the weapon of a player on a team
8. Upgrading the weapons of a whole team.

On top of automating the game creation process, i also want to explore how we can improve the fighting that the bots due within the BG, for this gameplan, i just want an analysis of how the system that drives the bots in the BG, its general order of operations, any general bugs that can be seen within the code, with the goal of providing insight into how we can make the bots better at playing the battleground in addition to just hunting for bugs

This work should utilize the unrestricted access to the stack and db, there are no live players, the agent working has full approval to bring the stack up and down as needed, and re-build and restart the server if an issue arrives.

Im not sure if this is available, but we need to make sure that we have proper telemetry for the bots within the BG, so that we can validate that the bots are indeed making their way into the BG, and will also be utilize to debug pathing within the BG
In addition to this, id like to better understand the best way we could capture the logs from the bot within the BG, so that it can be analyzed and debugged for odd bot behavior or used for refining their battleground playing capabilities

Another feature we need to figure out is how we can stream the gameplay footage to the players, multi boxing a few accounts and having their camera movemments scripted sounds like the best option for how we can treat this like a football game, but im not sure what kinda issues wed run into, or how we can retrieve the POV of a scripted AI, but we need a solution, i can fly around myself, but i want to understand if scripting a gm bot to fly around is a potential solution for following/streaming the game

The database thats available has no live players, we are free to create/delete bots at a whim, and we can always reset if need be. Do not fear deleting or creating new bots so long as its documented, we will eventually re-create all the bots once things are working, and proper rosters can be created with proper names, for now, utilize this syntax

Alliance = Wsga1....Wsga#
Horde = Wsgh1....Wsgh# 

There are probably more features and callouts to come, but this is a nice high level explanation of the overall goal that im trying to build.

The implementation play should utilize the scop and drain for automated implementation and testing. the existing scripts that were created for the WSG automation should act as the base work for this project, as it has already been determined how we can start a WSG game with bots, on command, this is the evolution of that idea. 