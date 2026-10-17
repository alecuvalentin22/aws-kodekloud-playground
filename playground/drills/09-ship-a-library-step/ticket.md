From: Priya (platform lead), cc Sam (payments)               #help-platform

  Sam just pasted the test-command block into demo-api's Jenkinsfile. That is
  the same block search-indexer and checkout already carry, and checkout's copy
  has already drifted (it lost the fail-fast flag a month ago and nobody
  noticed). I am not signing off on a fourth copy.

  Please make it a platform-lib step and ship it properly:

    - name it  pytestCommand. Called with NO arguments, it returns the test
      command as a String: what the block builds today, including "-x on
      anything that is not main".
    - release it as a new VERSION of platform-lib. Not "whatever is on main".
    - payments/demo-api moves onto it first, as the pilot. The block leaves
      its Jenkinsfile and demo-api stays green.
    - search-indexer stays on v1.0.0 until their release on Friday. If their
      build changes because of this, that is on us.

  Sam's block is in demo-api's Jenkinsfile right now. Thanks!
