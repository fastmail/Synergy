const boardEl = document.getElementById("board");
const board = [];

const splitflapValues = {
  0: " ",
  1: "A",
  2: "B",
  3: "C",
  4: "D",
  5: "E",
  6: "F",
  7: "G",
  8: "H",
  9: "I",
  10: "J",
  11: "K",
  12: "L",
  13: "M",
  14: "N",
  15: "O",
  16: "P",
  17: "Q",
  18: "R",
  19: "S",
  20: "T",
  21: "U",
  22: "V",
  23: "W",
  24: "X",
  25: "Y",
  26: "Z",
  27: "1",
  28: "2",
  29: "3",
  30: "4",
  31: "5",
  32: "6",
  33: "7",
  34: "8",
  35: "9",
  36: "0",
  37: "!",
  38: "@",
  39: "#",
  40: "$",
  41: "(",
  42: ")",
  44: "-",
  46: "+",
  47: "&",
  48: "=",
  49: ";",
  50: ":",
  52: "'",
  53: '"',
  54: "%",
  55: ",",
  56: ".",
  59: "/",
  60: "?",
  62: "°",
  63: "🟥", // "PoppyRed"
  64: "🟧", // "Orange"
  65: "🟨", // "Yellow"
  66: "🟩", // "Green"
  67: "🟦", // "ParisBlue"
  68: "🟪", // "Violet"
  69: "⬜", // "White"
};

let representation = [];
let workingRow;
let firstElement;

const url = new URL(window.location);
const startBoardText = url.searchParams.get("state");
let startBoard;
try {
  if (startBoardText) {
    startBoard = JSON.parse(
      decodeURI(RawDeflate.inflate(atob(startBoardText)))
    );
  }
} catch (_) {}

const jsonBlock = document.getElementById("json");
const updateJsonBlock = () => {
  representation = JSON.stringify(
    board.map((row) => [...row.map((column) => column.value)])
  );
  jsonBlock.innerText = representation;
  url.searchParams.set(
    "state",
    btoa(RawDeflate.deflate(encodeURI(representation)))
  );
  window.history.pushState({}, "", url);
};

const createSelectForCell = (boardCell) => {
  if (boardCell.j === 0) {
    workingRow = document.createElement("div");
    boardEl.appendChild(workingRow);
  }

  const newSelect = document.createElement("select");

  for (let key in splitflapValues) {
    const option = document.createElement("option");
    option.value = key;
    option.text = splitflapValues[key];
    newSelect.appendChild(option);
  }
  newSelect.value = boardCell.value;
  newSelect.className = "option-" + boardCell.value;
  workingRow.appendChild(newSelect);

  newSelect.onchange = (event) => {
    newSelect.className = "option-" + event.target.value;
    boardCell.value = +event.target.value;
    updateJsonBlock();
  };
  newSelect.onkeypress = (event) => {
    event.target.goNextCell();
  };
  boardCell.layer = newSelect;
  newSelect._data = boardCell;
  if (boardCell.i === 0 && boardCell.j === 0) {
    firstElement = newSelect;
  }
  newSelect.goNextCell = () => {
    let newTargetI = boardCell.i;
    let newTargetJ = boardCell.j;
    if (newTargetJ < 21) {
      newTargetJ++;
    } else if (newTargetI < 5) {
      newTargetI++;
      newTargetJ = 0;
    }
    const targetSelect = board[newTargetI][newTargetJ].layer;
    targetSelect.focus();
  };
  newSelect.goNextRow = () => {
    let newTargetI = boardCell.i;
    let newTargetJ = boardCell.j;
    if (newTargetI < 5) {
      newTargetI++;
      newTargetJ = 0;
    }
    const targetSelect = board[newTargetI][newTargetJ].layer;
    targetSelect.focus();
  };
  newSelect.backspace = () => {
    let newTargetI = boardCell.i;
    let newTargetJ = boardCell.j;
    if (newTargetJ === 0 && newTargetI > 0) {
      newTargetI--;
      newTargetJ = 21;
    } else if (newTargetI !== 0 || newTargetJ !== 0) {
      newTargetJ--;
    }
    const targetSelect = board[newTargetI][newTargetJ].layer;
    targetSelect.focus();
    targetSelect.value = " ";
  };
  newSelect.goLeft = () => {
    let newTargetI = boardCell.i;
    let newTargetJ = boardCell.j;
    if (newTargetJ > 0) {
      newTargetJ--;
    }
    const targetSelect = board[newTargetI][newTargetJ].layer;
    targetSelect.focus();
  };
  newSelect.goRight = () => {
    let newTargetI = boardCell.i;
    let newTargetJ = boardCell.j;
    if (newTargetJ < 22) {
      newTargetJ++;
    }
    const targetSelect = board[newTargetI][newTargetJ].layer;
    targetSelect.focus();
  };
  newSelect.goUp = () => {
    let newTargetI = boardCell.i;
    let newTargetJ = boardCell.j;
    if (newTargetI > 0) {
      newTargetI--;
    }
    const targetSelect = board[newTargetI][newTargetJ].layer;
    targetSelect.focus();
  };
  newSelect.goDown = () => {
    let newTargetI = boardCell.i;
    let newTargetJ = boardCell.j;
    if (newTargetI < 6) {
      newTargetI++;
    }
    const targetSelect = board[newTargetI][newTargetJ].layer;
    targetSelect.focus();
  };
};

const initializeCell = (boardCell) => {
  boardCell.value = 0;
  try {
    boardCell.value = startBoard[boardCell.i][boardCell.j];
  } catch (_) {}
  createSelectForCell(boardCell);
};

for (let i = 0; i < 6; i++) {
  board.push([]);
  for (let j = 0; j < 22; j++) {
    const newCell = {
      i,
      j,
    };
    initializeCell(newCell);
    board[i].push(newCell);
  }
}
updateJsonBlock();

window.onkeydown = (event) => {
  const active = document.activeElement;
  if (!active || !active._data) {
    firstElement.focus();
    if (event.key === "Tab") {
      event.preventDefault();
      event.stopPropagation();
    }
    return;
  }
  if (
    [
      " ",
      "Backspace",
      "Enter",
      "ArrowLeft",
      "ArrowRight",
      "ArrowUp",
      "ArrowDown",
    ].includes(event.key)
  ) {
    event.preventDefault();
    event.stopPropagation();
  } else {
    return;
  }
  if (event.key === " ") {
    event.target.goNextCell();
  }
  if (event.key === "Enter") {
    event.target.goNextRow();
  }
  if (event.key === "Backspace") {
    event.target.backspace();
  }
  if (event.key === "ArrowRight") {
    event.target.goRight();
  }
  if (event.key === "ArrowLeft") {
    event.target.goLeft();
  }
  if (event.key === "ArrowUp") {
    event.target.goUp();
  }
  if (event.key === "ArrowDown") {
    event.target.goDown();
  }
  updateJsonBlock();
};

const submitButton = document.getElementById("submit-button");

const setInfoBox = function (type, text) {
  const infoBox = document.getElementById("infobox");
  infoBox.className = type;
  infoBox.innerText = text;
};

submitButton.onclick = async function () {
  submitButton.disabled = true;
  const urlParams = new URLSearchParams(window.location.search);
  const payload = {
    username: urlParams.get("username"),
    secret: urlParams.get("secret"),
    board: JSON.parse(representation),
  };
  console.log(payload);
  try {
    await fetch(window.location.href.split("?")[0], {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify(payload),
    });
  } catch (err) {
    setInfoBox(
      "error",
      "Sorry, something's gone wrong!  You should probably show this to a friendly neighborhood plumber."
    );
    console.error(err);
    submitButton.disabled = false;
    return;
  }
  setInfoBox("success", "Your message has been submitted!");
  submitButton.disabled = false;
};
