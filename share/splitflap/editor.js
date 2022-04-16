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

const splitFlapKeys = {};
Object.keys(splitflapValues).forEach(
  (key) => (splitFlapKeys[splitflapValues[key]] = key)
);

let representation = [];
let workingRow;
let firstElement;
let numbersAreColors = false;

const encodeBoard = (board) => {
  let string = "";
  let queue = board.flat().map((e) => e.value); // Eh.

  while (queue.length) {
    const code = queue.shift();

    if (queue.length >= 2 && queue[0] === code && queue[1] === code) {
      let n = 3;

      queue.splice(0, 2);

      while (queue.length && queue[0] === code) {
        n++;
        queue.shift();
      }

      string += String.fromCharCode(code | 128);
      string += String.fromCharCode(n);

      continue;
    }

    string += String.fromCharCode(code);
  }

  return btoa(string).replaceAll('+', '-')
                     .replaceAll('/', '_')
                     .replaceAll(/=+$/g, '');
};

const decodeBoard = (string) => {
  string.replaceAll('-', '+').replaceAll('_', '/');
  string = atob(string);

  let codes = []

  const iterator = string[Symbol.iterator]();
  let queue = Array.from(iterator);

  while (queue.length) {
    const char = queue.shift().codePointAt(0);

    if (char & 128) {
      if (queue.length === 0) throw("underrun!");

      const code = char ^ 128;
      const run  = queue.shift().codePointAt(0);

      codes.push( ...(Array(run).fill(code)) );
      continue;
    }

    codes.push(char);
  }

  if (codes.length !== 6*22) {
    console.log(`wrong length for encoded board: ${codes.length}`);
    return Array(6).fill(Array(22).fill(0));
  }

  const a = Array(6).fill(1).map(i => codes.splice(0,22));
  return a;
};

const url = new URL(window.location);
const startBoardText = url.searchParams.get("state");
const designText = url.searchParams.get("design");
let startBoard;
try {
  if (startBoardText) {
    startBoard = decodeBoard(startBoardText);
  }
} catch (_) {}
if (designText) {
  document.getElementById("design-input").value = designText;
}

const jsonBlock = document.getElementById("json");
const updateJsonBlock = () => {
  representation = JSON.stringify(
    board.map((row) => [...row.map((column) => column.value)])
  );
  jsonBlock.innerText = representation;
  url.searchParams.set("state", encodeBoard(board));
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
  newSelect.writeRaw = (num) => {
    newSelect.value = num;
    boardCell.value = num;
  };
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
    if (!Number(newSelect.value)) {
      let newTargetI = boardCell.i;
      let newTargetJ = boardCell.j;
      if (newTargetJ === 0 && newTargetI > 0) {
        newTargetI--;
        newTargetJ = 21;
      } else if (newTargetI !== 0 || newTargetJ !== 0) {
        newTargetJ--;
      }
      const targetSelect = board[newTargetI][newTargetJ].layer;
      board[newTargetI][newTargetJ].value = 0;
      targetSelect.focus();
      targetSelect.value = " ";
    } else {
      newSelect.writeRaw(0);
    }
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
  const thisNumber = Number(event.key);
  const shouldPaint =
    !Number.isNaN(thisNumber) && thisNumber >= 1 && thisNumber <= 7;
  let target = event.target;

  if (!active || !active._data) {
    if (active && active.id === "design-input") {
      return;
    }
    firstElement.focus();
    if (event.key === "Tab") {
      event.preventDefault();
      event.stopPropagation();
    }
    if (!shouldPaint) {
      return;
    } else {
      target = firstElement;
    }
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
  } else if (numbersAreColors) {
    const thisNumber = Number(event.key);
    if (shouldPaint) {
      // fun hack:  63 is PoppyRed, so let's just count up from there!
      target.writeRaw(62 + thisNumber);
      target.goNextCell();
      event.preventDefault();
      event.stopPropagation();
    }
  } else {
    target.writeRaw(splitFlapKeys[event.key && event.key.toUpperCase()]);
    return;
  }
  if (event.key === " ") {
    target.goNextCell();
  }
  if (event.key === "Enter") {
    target.goNextRow();
  }
  if (event.key === "Backspace") {
    target.backspace();
  }
  if (event.key === "ArrowRight") {
    target.goRight();
  }
  if (event.key === "ArrowLeft") {
    target.goLeft();
  }
  if (event.key === "ArrowUp") {
    target.goUp();
  }
  if (event.key === "ArrowDown") {
    target.goDown();
  }
  updateJsonBlock();
};

const designInput = document.getElementById("design-input");
designInput.onkeyup = () => {
  url.searchParams.set("design", designInput.value);
  window.history.pushState({}, "", url);
};

const submitButton = document.getElementById("submit-button");

const setInfoBox = function (type, text) {
  const infoBox = document.getElementById("infobox");
  infoBox.className = type;
  infoBox.innerText = text;
};

const checkParams = new URLSearchParams(window.location.search);
if (!checkParams.get("username") || !checkParams.get("secret")) {
  setInfoBox(
    "error",
    "There seems to be a problem with your submission token.  Your attempts to save your design will probably fail!"
  );
}

submitButton.onclick = async function () {
  submitButton.disabled = true;
  const urlParams = new URLSearchParams(window.location.search);
  const design = urlParams.get("design");

  if (!design) {
    setInfoBox("error", "Please name your design!");
    submitButton.disabled = false;
    return;
  }

  const payload = {
    username: urlParams.get("username"),
    secret: urlParams.get("secret"),
    board: JSON.parse(representation),
    design,
  };
  console.log(payload);
  try {
    const response = await fetch(window.location.href.split("?")[0], {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify(payload),
    });
    if (response.status !== 200) {
      throw new Error("Bad response: " + response.statusText);
    }
    setInfoBox("success", "Your message has been submitted!");
    submitButton.disabled = false;
  } catch (err) {
    setInfoBox(
      "error",
      "Sorry, something's gone wrong!  You should probably show this to a friendly neighborhood plumber."
    );
    console.error(err);
    submitButton.disabled = false;
    return;
  }
};

document.getElementById("showstate-button").onclick = () => {
  jsonBlock.classList.toggle("show");
};

document.getElementById("clearboard-button").onclick = () => {
  if (confirm("Are you sure?")) {
    for (let i = 0; i < 6; i++) {
      for (let j = 0; j < 22; j++) {
        board[i][j].value = 0;
        board[i][j].layer.value = " ";
      }
    }
    updateJsonBlock();
  }
};

document.getElementById("colors-button").onclick = () => {
  document.getElementById("legend").classList.toggle("hidden");
  numbersAreColors = !numbersAreColors;
};
