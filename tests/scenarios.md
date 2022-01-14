## Test Scenarios

Any pull request/workflow_dispatch in timburganec/timburgan, will
trigger test workflow.

That workflow will itself trigger timburgan/chess-workflow-tester
which will return PASS or FAIL.

### SETUP

- delete issues
- readme - current board positions, next steps, last moves, top movers
- PGN game file
- issues
- stats

### TEST SCENARIOS

1. game is valid - allow user to move
2. game data file doesn't exist
3. game data file corrupt
4. game data file contains invalid move
5. same user just moved in last step
6. game is now checkmate
7. invalid issue title issued = m0ve
8. invalid issue title issued = ch3ss
9. force new game midway through via timburgan
10. force new game midway through via other person
11. force new game when gameover via other person
12. stats populated correctly from existing issues
13. high score populated correctly from existing issues (see leaderboard.legacy.txt)
14. 

### ASSERRTIONS

- issue reactions as expected
- issue comments as expected
- issue status as expected
- game file as expected
- stats file as expected
