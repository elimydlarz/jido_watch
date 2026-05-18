# Test Trees

## Functional

### watching

```
watching (functional: test/functional/watching_test.exs)
  when the user watches new content
    then the agent's watch/2 is called once per chunk
    then the agent's experience/3 is called once per angle, with the experiences from watch
    then the agent's form_opinion/2 is called once with the impressions from each angle
  when the user has not watched anything new
    then no callbacks are called
  when content the user watched cannot be processed
    then form_opinion/2 is not called
```

### setup

```
setup (functional: test/functional/setup_test.exs)
  when the agent calls the setup_jido_watch action for an unconnected user
    then an authorization URL is returned
  when called with a valid auth code for that user
    then the user becomes connected
  when called with an invalid code
    then the user does not become connected
  when a user is not connected
    then no watching happens for them
```
