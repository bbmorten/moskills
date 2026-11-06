---
tags: [skill-creator]
max_turns: 20
timeout_seconds: 600
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit, Bash]
---

make this sound more human please, it's going into our ops wiki

We moved the nightly backup from 22:00 to 23:00 because the old slot collided with the reporting job, which reads the same tables. Since the change, the backup has finished in about 40 minutes every night, down from 70. If a backup fails, the operator gets an email and the next night's run starts as usual; nothing retries during the day. However, a backup that is still running at 07:00 is stopped, because that is when people start using the system. We keep three things for 30 days: the database dump, the uploaded files and the configuration.
