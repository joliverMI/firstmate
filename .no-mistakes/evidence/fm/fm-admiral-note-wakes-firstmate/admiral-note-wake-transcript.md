# Admiral note wakes firstmate - end-to-end CLI transcript

Fresh temporary FM_HOME, real board process started through bin/fm-dashboard.sh, driven only via the CLI and HTTP API.

```
$ /home/joliv/.no-mistakes/worktrees/4cc5c0885385/01M2086S42GW8BK4Z4ZCY1NF9C/bin/fm-dashboard.sh start
fleet dashboard started (pid 2824766) - http://127.0.0.1:38707/  api reachable at http://127.0.0.1:38707/api/health  log: /tmp/fm-note-e2e.fXlJyB/state/dashboard.log
$ fm-dashboard.sh add ...  -> card board-card-the-admiral-asks-about-ows7

## 1. The Admiral writes a communication note (the reported bug scenario)
$ fm-dashboard.sh note board-card-the-admiral-asks-about-ows7 --tab communication --author admiral --text 'is this still needing attention?'
board-card-the-admiral-asks-about-ows7: note added to communication

$ cat $FM_HOME/state/.wake-queue   (tab-separated; firstmate's durable wake queue)
1788863050 <TAB> 1 <TAB> check <TAB> dashboard-note:board-card-the-admiral-asks-about-ows7 <TAB> check: dashboard-note board-card-the-admiral-asks-about-ows7 - he wrote on the card; read and answer it

## 2. firstmate's own wake drain (bin/fm-wake-drain.sh) reads it back
$ FM_HOME=<copy> bin/fm-wake-drain.sh
1788863050	1	check	dashboard-note:board-card-the-admiral-asks-about-ows7	check: dashboard-note board-card-the-admiral-asks-about-ows7 - he wrote on the card; read and answer it
WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 1 --recovery-generation 2825763.1788863050.veQEKp

## 3. An agent-authored note publishes nothing
$ fm-dashboard.sh note board-card-the-admiral-asks-about-ows7 --tab communication --author agent --text 'routine update'
board-card-the-admiral-asks-about-ows7: note added to communication
$ grep -c 'dashboard-note:board-card-the-admiral-asks-about-ows7' $FM_HOME/state/.wake-queue
1
(still exactly one record: the admiral's; the agent note added none)

## 4. Wake queue made unwritable: the note still saves, failure is loud
$ chmod 000 $FM_HOME/state
$ curl -X POST /api/tasks/board-card-the-admiral-asks-about-ows7/notes -d '{"tab":"communication","author":"admiral","text":"still there?"}'
{
  "id": "board-card-the-admiral-asks-about-ows7",
  "communication_notes": [
    {
      "id": 1,
      "task_id": "board-card-the-admiral-asks-about-ows7",
      "tab": "communication",
      "author": "admiral",
      "text": "is this still needing attention?",
      "link_url": null,
      "link_label": null,
      "created_at": "2026-09-08T10:24:10Z"
    },
    {
      "id": 2,
      "task_id": "board-card-the-admiral-asks-about-ows7",
      "tab": "communication",
      "author": "agent",
      "text": "routine update",
      "link_url": null,
      "link_label": null,
      "created_at": "2026-09-08T10:24:10Z"
    },
    {
      "id": 3,
      "task_id": "board-card-the-admiral-asks-about-ows7",
      "tab": "communication",
      "author": "admiral",
      "text": "still there?",
      "link_url": null,
      "link_label": null,
      "created_at": "2026-09-08T10:24:10Z"
    }
  ]
}
HTTP 201
$ chmod 755 $FM_HOME/state

$ fm-dashboard.sh show board-card-the-admiral-asks-about-ows7
id:       board-card-the-admiral-asks-about-ows7
title:    Board card the Admiral asks about
status:   not_started
captain:  firstmate
agent:    
starred:  false

--- prompt ---
verify the note wake

--- communication ---
[admiral 2026-09-08T10:24:10Z] is this still needing attention?
[agent 2026-09-08T10:24:10Z] routine update
[admiral 2026-09-08T10:24:10Z] still there?

$ grep dashboard-note $FM_HOME/state/.wake-queue   (no second admiral record: the publish really failed)
1

$ cat $FM_HOME/state/dashboard.log   (server stderr - the loud failure)
fleet dashboard listening on http://127.0.0.1:38707  (db: /tmp/fm-note-e2e.fXlJyB/data/dashboard.db)
dashboard: NOTE NOT ANNOUNCED for board-card-the-admiral-asks-about-ows7 - he wrote on the card but firstmate was not woken: firstmate's wake-queue writer did not finish within 5s. Read and answer it by hand.

$ curl /api/audit/status | jq .log   (the board's own discrepancy log)
[
  {
    "id": 1,
    "task_id": "board-card-the-admiral-asks-about-ows7",
    "kind": "error",
    "text": "he wrote on this card, but firstmate could not be notified (firstmate's wake-queue writer did not finish within 5s) - this card needs reading and answering by hand",
    "key": "note-wake-unpublished",
    "occurrences": 1,
    "created_at": "2026-09-08T10:24:15Z",
    "last_seen_at": "2026-09-08T10:24:15Z"
  }
]
```
