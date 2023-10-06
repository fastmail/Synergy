# Connecting Synergy to Discord

First, you need a Discord application.  You can make one of those in the
[Developer Portal](https://discord.com/developers/applications).

You'll get an application id, public key, and secret key.

With that created, you need to make a Bot user.  You can do that from the
application page for your application.  There's a 🧩 icon in the sidebar and it
says "Bot".

On that page, you give it a username, set permissions, and get a token.  The
token will be given only once, so save it!

You need to set some **Privileged Gateway Intents** on your bot.  Specifically,
it needs "Server Members Intent" so it can see every user on the server to
resolve info about them.  Secondly, it needs "Message Content Intent" so it can
be notified of every message sent.

Without these, it would be possible to the bot work with only targeted
messages, probably… but we've never tested that configuration.

Now you should have these three bits of information about your bot:

* the **application id** from creating the application
* the **secret key** from creating the application
* the **bot token**

You can add the channel to your Synergy configuration like this:

```json
"channels": {
  "discord": {
    "class": "Synergy::Channel::Discord",
    "bot_token": "some-long-random-looking-string"
  }
}
```

You'll also need to authorize the application to join your server.

This is documented unde the [Authorization Code
Grant](https://discord.com/developers/docs/topics/oauth2#authorization-code-grant)
section of the Discord develoepr docs.

You build a URL like this:

```
https://discord.com/api/oauth2/authorize?client_id=$APPID&scope=bot&permissions=85056
```

The `permissions` value come from the [permissions
bitfield](https://discord.com/developers/docs/topics/permissions) like this:

```perl
my $permissions = 0x00040 # Add reactions
                | 0x00400 # View channel
                | 0x00800 # Send messages
                | 0x04000 # EMBED_LINKS
                | 0x10000 # READ_MESSAGE_HISTORY
                ;
```

It seems that recent API changes allow permissions to be described as strings,
but the docs haven't been updated nor the process tested.
