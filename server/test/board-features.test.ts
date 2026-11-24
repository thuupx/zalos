import { test, expect, beforeAll, afterAll } from "bun:test";
import {
  makeEnv,
  pairDevice,
  controlClient,
  accountClient,
  loginQrAccount,
  type TestEnv,
  type PairedDevice,
} from "./support/helpers.ts";
import type { FakeGateway } from "../src/gateway/fake.ts";
import type {
  PinBoardState,
  PinnedTopic,
  PollDetail,
  ReminderItem,
} from "../src/gateway/types.ts";

let env: TestEnv;
let admin: PairedDevice;
let slot: string;
let gw: FakeGateway;

beforeAll(async () => {
  env = await makeEnv({ autoDeleteSweepMs: 0 });
  admin = await pairDevice(env, { name: "admin" });
  const control = await controlClient(env, admin);
  slot = await loginQrAccount(env, control);
  gw = env.factory.gateways.at(-1)!;
  control.close();
});

afterAll(() => env.cleanup());

test("pin and unpin messages in both group and 1:1 chats", async () => {
  const client = await accountClient(env, admin, slot);
  try {
    // 1:1 chat pin
    const dmPinned = (await client.request("pins.pinMessage", {
      threadId: "u-pin-1",
      threadType: "user",
      msgId: "m-dm-1",
      cliMsgId: "c-dm-1",
      title: "Nhớ mang hợp đồng nha",
      senderName: "Lan",
    })) as PinBoardState;
    expect(dmPinned.items.length).toBe(1);
    expect(dmPinned.items[0]!.kind).toBe("message");
    expect(dmPinned.items[0]!.title).toBe("Nhớ mang hợp đồng nha");

    const dmList = (await client.request("pins.list", {
      threadId: "u-pin-1",
      threadType: "user",
    })) as PinBoardState;
    expect(dmList.items.length).toBe(1);

    const dmUnpinned = (await client.request("pins.unpin", {
      threadId: "u-pin-1",
      threadType: "user",
      topicId: dmPinned.items[0]!.id,
      topicType: dmPinned.items[0]!.topicType,
    })) as PinBoardState;
    expect(dmUnpinned.items.length).toBe(0);

    // Group chat pin + board list
    const grpPinned = (await client.request("pins.pinMessage", {
      threadId: "g-pin-1",
      threadType: "group",
      msgId: "m-grp-1",
      cliMsgId: "c-grp-1",
      title: "Lịch họp 9h sáng mai",
      senderName: "Bảo",
    })) as PinBoardState;
    expect(grpPinned.items.length).toBe(1);
    expect(grpPinned.items[0]!.msgId).toBe("m-grp-1");

    const board = (await client.request("board.list", {
      groupId: "g-pin-1",
    })) as { items: PinnedTopic[] };
    expect(board.items.some((x) => x.id === grpPinned.items[0]!.id)).toBe(true);
  } finally {
    client.close();
  }
});

test("group poll lifecycle: create, detail, vote, addOption, pin, share, lock", async () => {
  const client = await accountClient(env, admin, slot);
  try {
    const created = (await client.request("polls.create", {
      groupId: "g-poll-1",
      question: "Trưa nay ăn gì?",
      options: ["Bún chả", "Phở bò"],
      allowMultiChoices: true,
      allowAddNewOption: true,
      hideVotePreview: false,
      isAnonymous: false,
      pin: true,
    })) as { poll: PollDetail };

    expect(created.poll.question).toBe("Trưa nay ăn gì?");
    expect(created.poll.options.length).toBe(2);
    expect(created.poll.closed).toBe(false);

    // Pinned automatically because pin: true
    const pins = (await client.request("pins.list", {
      threadId: "g-poll-1",
      threadType: "group",
    })) as PinBoardState;
    expect(pins.items.some((t) => t.kind === "poll" && t.pollId === created.poll.id)).toBe(true);

    // Vote on option 0
    const firstOptId = created.poll.options[0]!.id;
    const voted = (await client.request("polls.vote", {
      pollId: created.poll.id,
      optionIds: [firstOptId],
      groupId: "g-poll-1",
    })) as { poll: PollDetail };
    expect(voted.poll.options[0]!.voted).toBe(true);
    expect(voted.poll.options[0]!.votes).toBe(1);

    // Add a new option
    const withNewOpt = (await client.request("polls.addOption", {
      pollId: created.poll.id,
      content: "Cơm tấm",
      votedOptionIds: [firstOptId],
      voteNew: true,
      groupId: "g-poll-1",
    })) as { poll: PollDetail };
    expect(withNewOpt.poll.options.length).toBe(3);
    expect(withNewOpt.poll.options[2]!.content).toBe("Cơm tấm");

    // Share poll
    const shared = (await client.request("polls.share", {
      pollId: created.poll.id,
    })) as { ok: boolean };
    expect(shared.ok).toBe(true);

    // Lock poll
    const locked = (await client.request("polls.lock", {
      pollId: created.poll.id,
      groupId: "g-poll-1",
    })) as { poll: PollDetail };
    expect(locked.poll.closed).toBe(true);

    // Detail reflects locked state
    const detail = (await client.request("polls.detail", {
      pollId: created.poll.id,
      groupId: "g-poll-1",
    })) as { poll: PollDetail };
    expect(detail.poll.closed).toBe(true);
  } finally {
    client.close();
  }
});

test("group notes create, edit, and reminders create/list/edit/remove", async () => {
  const client = await accountClient(env, admin, slot);
  try {
    const note = (await client.request("notes.create", {
      groupId: "g-note-1",
      title: "Wifi văn phòng: zalos2026",
      pin: true,
    })) as { note: PinnedTopic };
    expect(note.note.kind).toBe("note");
    expect(note.note.title).toBe("Wifi văn phòng: zalos2026");

    const edited = (await client.request("notes.edit", {
      groupId: "g-note-1",
      topicId: note.note.id,
      title: "Wifi mới: zalos2027",
      pin: true,
    })) as { note: PinnedTopic };
    expect(edited.note.title).toBe("Wifi mới: zalos2027");

    // Reminders in 1:1 and group
    const rem = (await client.request("reminders.create", {
      threadId: "g-note-1",
      threadType: "group",
      title: "Đóng quỹ nhóm",
      startTime: Date.now() + 3600_000,
      repeat: 2,
    })) as { reminder: ReminderItem };
    expect(rem.reminder.title).toBe("Đóng quỹ nhóm");
    expect(rem.reminder.repeat).toBe(2);

    const listed = (await client.request("reminders.list", {
      threadId: "g-note-1",
      threadType: "group",
    })) as { reminders: ReminderItem[] };
    expect(listed.reminders.some((r) => r.id === rem.reminder.id)).toBe(true);

    const updated = (await client.request("reminders.edit", {
      threadId: "g-note-1",
      threadType: "group",
      id: rem.reminder.id,
      title: "Đóng quỹ nhóm trước thứ 6",
      repeat: 1,
    })) as { reminder: ReminderItem };
    expect(updated.reminder.title).toBe("Đóng quỹ nhóm trước thứ 6");

    await client.request("reminders.remove", {
      threadId: "g-note-1",
      threadType: "group",
      id: rem.reminder.id,
    });
    const afterRemove = (await client.request("reminders.list", {
      threadId: "g-note-1",
      threadType: "group",
    })) as { reminders: ReminderItem[] };
    expect(afterRemove.reminders.some((r) => r.id === rem.reminder.id)).toBe(false);
  } finally {
    client.close();
  }
});

test("board.updated event broadcasts on pin/poll/note group events", async () => {
  const client = await accountClient(env, admin, slot);
  try {
    client.events.length = 0;
    gw.emit("groupEvent", {
      type: "pin_topic",
      groupId: "g-live-1",
    });
    const evt = await client.waitEvent("board.updated", 3000);
    expect(evt.data).toEqual({ threadId: "g-live-1", threadType: "group" });
  } finally {
    client.close();
  }
});
