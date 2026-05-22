FROM node:20-alpine

RUN apk add --no-cache git

# Clone send2ereader and install production dependencies
RUN git clone --depth 1 https://github.com/daniel-j/send2ereader /app \
    && cd /app \
    && sed -i 's/const expireDelay = 30/const expireDelay = 600/' index.js \
    && node -e "const fs=require('fs'); let c=fs.readFileSync('index.js','utf8'); c=c.replace(/if\s*\(info\.agent\s*!==\s*ctx\.get\('user-agent'\)\)[^}]+\}/g,''); fs.writeFileSync('index.js',c);" \
    && node -e " \
const fs=require('fs'); \
let h=fs.readFileSync('static/download.html','utf8'); \
h=h.replace('<hr/>', \
'<hr/><div class=\"center\"><div style=\"font-size:1.1em;margin-bottom:6px\">Or enter a code from the addon logs:</div><div><input id=\"codeInput\" type=\"text\" maxlength=\"4\" placeholder=\"e.g. U935\" style=\"font-size:2em;width:4em;text-align:center;text-transform:uppercase;letter-spacing:4px\"> <button id=\"codeFetch\">Get book</button></div></div><hr/>'); \
h=h.replace('window.onload = function () {', \
'document.addEventListener(\"DOMContentLoaded\",function(){\
  document.getElementById(\"codeInput\").addEventListener(\"keydown\",function(e){if(e.key===\"Enter\")document.getElementById(\"codeFetch\").click();});\
  document.getElementById(\"codeFetch\").addEventListener(\"click\",function(){\
    var v=document.getElementById(\"codeInput\").value.trim().toUpperCase();\
    if(!v)return;\
    if(pollTimer)clearInterval(pollTimer);\
    key=v;keyOutput.textContent=key;\
    downloads.style.display=\"none\";\
    pollFile();\
    pollTimer=setInterval(pollFile,3000);\
  });\
});\
window.onload = function () {'); \
fs.writeFileSync('static/download.html',h);" \
    && npm ci --production

WORKDIR /app
EXPOSE 3001

COPY run.sh /run.sh
RUN chmod +x /run.sh

ENTRYPOINT ["/run.sh"]
