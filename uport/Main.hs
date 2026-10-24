{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module Main where

import Web.Scotty
import Network.HTTP.Types (status400, status403, status404, status413, status401)
import Network.Wai.Parse (FileInfo(..))
import Control.Concurrent.STM
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Char8 as BS
import Data.UUID (toText)
import Data.UUID.V4 (nextRandom)
import Data.String.Interpolate (i)
import System.FilePath ((</>))
import qualified System.Directory as Dir
import System.Environment (lookupEnv)
import Data.Maybe (fromMaybe)

import Types
import Storage

main :: IO ()
main = do
    portStr <- lookupEnv "PORT"
    let port = fromMaybe 8080 (portStr >>= \s -> case reads s of [(p, "")] -> Just p; _ -> Nothing)

    dirStr <- lookupEnv "UPLOAD_DIR"
    let storagePath = fromMaybe "/tmp/uport-uploads" dirStr
    let storage = LocalStorage storagePath

    baseUrlEnv <- lookupEnv "BASE_URL"
    let baseUrl = fromMaybe ("http://localhost:" ++ show port) baseUrlEnv

    portals <- newTVarIO M.empty
    putStrLn $ "Starting uport server on " ++ baseUrl
    putStrLn $ "Admin dashboard available at " ++ baseUrl ++ "/admin"

    scotty port $ do
        -- Admin Dashboard Page
        get "/admin" $ do
            html $ TL.fromStrict adminHTML

        -- Upload Portal Page
        get "/upload/:token" $ do
            token <- pathParam "token" :: ActionM TL.Text
            store <- liftIO $ readTVarIO portals
            case M.lookup (TL.toStrict token) store of
                Nothing -> status status404 >> html "<h2>Invalid or expired portal link.</h2>"
                Just _  -> html $ TL.fromStrict (uploadHTML (TL.toStrict token))

        -- Receive / Download Dashboard Page
        get "/receive/:token" $ do
            token <- pathParam "token" :: ActionM TL.Text
            store <- liftIO $ readTVarIO portals
            case M.lookup (TL.toStrict token) store of
                Nothing -> status status404 >> html "<h2>Invalid or expired portal link.</h2>"
                Just _  -> html $ TL.fromStrict (receiveHTML (TL.toStrict token))

        -- OTP Authentication Endpoint
        post "/api/auth/:token" $ do
            tokenParam <- pathParam "token" :: ActionM TL.Text
            let token = TL.toStrict tokenParam
            req <- jsonData :: ActionM AuthRequest
            store <- liftIO $ readTVarIO portals
            case M.lookup token store of
                Nothing -> status status404 >> text "Portal not found."
                Just state ->
                    if psOtp state == authOtp req
                        then json True
                        else status status401 >> text "Invalid OTP code."

        -- Realtime Status API (Polled by Receive Page)
        get "/api/status/:token" $ do
            token <- pathParam "token" :: ActionM TL.Text
            store <- liftIO $ readTVarIO portals
            case M.lookup (TL.toStrict token) store of
                Nothing    -> status status404 >> text "Not found"
                Just state -> json state

        -- Handle File Upload Submission
        post "/api/upload/:token" $ do
            tokenParam <- pathParam "token" :: ActionM TL.Text
            let token = TL.toStrict tokenParam
            store <- liftIO $ readTVarIO portals
            case M.lookup token store of
                Nothing -> status status404 >> text "Portal token not found."
                Just state -> do
                    if psCurrentUses state >= psMaxUses state
                        then status status403 >> text "Upload limit reached."
                        else do
                            fs <- files
                            let maxBytes = fromIntegral (psMaxFileSizeMB state) * 1024 * 1024
                            if length fs > psMaxFiles state
                                then status status400 >> text "Exceeded maximum allowed files."
                                else do
                                    let uploadResults = mapM (\(_, fi) -> do
                                            let name = BS.unpack (fileName fi)
                                            let content = fileContent fi
                                            if BL.length content > maxBytes
                                                then pure (Left "File exceeds size limit.")
                                                else do
                                                    res <- saveFile storage token name content
                                                    pure (case res of
                                                        Left err -> Left err
                                                        Right () -> Right (UploadedFileMeta (T.pack name) (fromIntegral $ BL.length content)))
                                            ) fs

                                    results <- liftIO uploadResults
                                    let (errs, metas) = foldr (\r (es, ms) -> case r of Left e -> (e:es, ms); Right m -> (es, m:ms)) ([], []) results
                                    if not (null errs)
                                        then status status413 >> text "One or more files failed size limits."
                                        else do
                                            liftIO $ atomically $ modifyTVar' portals $ M.adjust
                                                (\s -> s { psCurrentUses = psCurrentUses s + 1
                                                         , psFiles       = psFiles s ++ metas }) token
                                            text "Files uploaded successfully!"

        -- Download Specific Uploaded File
        get "/api/download/:token/:filename" $ do
            tokenParam <- pathParam "token" :: ActionM TL.Text
            filenameParam <- pathParam "filename" :: ActionM TL.Text
            let token = TL.toStrict tokenParam
            let filename = TL.toStrict filenameParam
            let filePath = storagePath </> T.unpack token </> T.unpack filename
            exists <- liftIO $ Dir.doesFileExist filePath
            if exists
                then file filePath
                else status status404 >> text "File not found."

        -- Admin Link Generation API
        post "/api/admin/create" $ do
            req <- jsonData :: ActionM CreatePortalRequest
            newToken <- liftIO $ fmap toText nextRandom
            let generatedOtp = T.take 6 newToken
            let state = PortalState
                    { psMaxFiles      = reqMaxFiles req
                    , psMaxFileSizeMB = reqMaxFileSizeMB req
                    , psMaxUses       = reqMaxUses req
                    , psCurrentUses   = 0
                    , psFiles         = []
                    , psOtp           = generatedOtp
                    , psExpiresAt     = reqExpiresAt req
                    }
            liftIO $ atomically $ modifyTVar' portals (M.insert newToken state)
            let base = T.pack baseUrl
            json CreatePortalResponse
                { uploadToken  = newToken
                , uploadUrl    = base <> "/upload/" <> newToken
                , receiveToken = newToken
                , receiveUrl   = base <> "/receive/" <> newToken
                , portalOtp    = generatedOtp
                }

--------------------------------------------------------------------------------
-- Frontend HTML Templates
--------------------------------------------------------------------------------

styleHTML :: T.Text
styleHTML = [i|
<style>
  body { font-family: system-ui, sans-serif; background: \#f8fafc; display: flex; align-items: center; justify-content: center; min-height: 100vh; margin: 0; box-sizing: border-box; padding: 1rem; }
  .card { background: white; padding: 2rem; border-radius: 12px; box-shadow: 0 4px 6px -1px rgba(0,0,0,0.1); width: 100%; max-width: 480px; box-sizing: border-box; }
  h2 { margin-top: 0; text-align: center; }
  .form-group { margin-bottom: 1rem; }
  label { display: block; font-size: 0.85rem; font-weight: 500; color: \#475569; margin-bottom: 0.25rem; }
  input[type=number] { width: 100%; padding: 0.5rem; border: 1px solid \#cbd5e1; border-radius: 6px; box-sizing: border-box; font-size: 1rem; }
  input[type=text] { padding: 0.5rem; width: 100%; max-width: 250px; font-size: 1rem; border: 1px solid \#cbd5e1; border-radius: 6px; margin-bottom: 1rem; text-align: center; letter-spacing: 2px; box-sizing: border-box; display: block; margin-left: auto; margin-right: auto; }
  button { background: \#2563eb; color: white; border: none; padding: 0.5rem 1rem; border-radius: 6px; font-size: 1rem; cursor: pointer; display: block; margin-left: auto; margin-right: auto; font-weight: 500; }
  button:hover { background: \#1d4ed8; }
  button.primary { width: 100%; padding: 0.75rem; margin-top: 0.5rem; }
  .dropzone { border: 2px dashed \#94a3b8; border-radius: 8px; padding: 2rem; cursor: pointer; transition: 0.2s; box-sizing: border-box; text-align: center; }
  .dropzone.dragover { border-color: \#16a34a; background: \#f0fdf4; }
  \#status { margin-top: 1rem; font-weight: 500; font-size: 0.9rem; word-break: break-all; text-align: center; }
  \#info { font-size: 0.85rem; color: \#64748b; text-align: center; margin-top: 1rem; }
  .result { margin-top: 1.5rem; background: \#f1f5f9; padding: 1rem; border-radius: 8px; font-size: 0.85rem; box-sizing: border-box; }
  .result p { margin: 0.75rem 0; word-break: break-all; display: flex; flex-direction: column; gap: 0.25rem; }
  .link-row { display: flex; align-items: center; justify-content: space-between; gap: 0.5rem; background: white; padding: 0.4rem 0.6rem; border: 1px solid \#cbd5e1; border-radius: 6px; }
  .link-row a { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: \#2563eb; text-decoration: none; }
  .link-row a:hover { text-decoration: underline; }
  button.copy-btn { background: \#e2e8f0; color: \#334155; border: none; padding: 0.3rem 0.6rem; border-radius: 4px; font-size: 0.75rem; font-weight: 600; cursor: pointer; white-space: nowrap; width: auto; margin: 0; display: inline-block; }
  button.copy-btn:hover { background: \#cbd5e1; }
  ul { list-style: none; padding: 0; margin: 1rem 0; max-height: 250px; overflow-y: auto; }
  li { display: flex; justify-content: space-between; align-items: center; padding: 0.75rem 0; border-bottom: 1px solid \#e2e8f0; gap: 0.5rem; word-break: break-all; }
  .badge { background: \#dcfce7; color: \#16a34a; padding: 0.25rem 0.6rem; border-radius: 9999px; font-size: 0.75rem; font-weight: 600; white-space: nowrap; }
  a.btn { background: \#2563eb; color: white; padding: 0.4rem 0.8rem; border-radius: 6px; text-decoration: none; font-size: 0.85rem; white-space: nowrap; }
  a.btn:hover { background: \#1d4ed8; }
  .otp-badge { background: \#dcfce7; color: \#16a34a; padding: 0.2rem 0.5rem; border-radius: 4px; font-weight: bold; font-family: monospace; }
  .hidden { display: none !important; }
</style>
|]

adminHTML :: T.Text
adminHTML = [i|<!DOCTYPE html>
<html>
  <head>
    <meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>uport - Admin Dashboard</title>
      #{styleHTML}
  </head>
  <body>
    <div class="card">
      <h2>Admin Dashboard</h2>
      <div class="form-group">
        <label>Max Files</label>
        <input type="number" id="maxFiles" value="5">
      </div>
      <div class="form-group">
        <label>Max File Size (MB)</label>
        <input type="number" id="maxFileSizeMB" value="50">
      </div>
      <div class="form-group">
        <label>Max Uses</label>
        <input type="number" id="maxUses" value="1">
      </div>
      <button class="primary" onclick="createPortal()">Generate Portal Links</button>
      <div id="resultBox" class="result hidden">
        <p>
          <b>Upload Link:</b>
          <span class="link-row">
            <a id="uploadLink" href="\#" target="_blank"></a>
            <button class="copy-btn" onclick="copyLink('uploadLink', this)">Copy</button>
          </span>
        </p>
        <p>
          <b>Receive Link:</b>
          <span class="link-row">
            <a id="receiveLink" href="\#" target="_blank"></a>
            <button class="copy-btn" onclick="copyLink('receiveLink', this)">Copy</button>
          </span>
        </p>
        <p><b>OTP PIN:</b> <span id="otpText" class="otp-badge"></span></p>
      </div>
    </div>
    <script>
      function createPortal() {
        const data = {
          reqMaxFiles: parseInt(document.getElementById('maxFiles').value),
          reqMaxFileSizeMB: parseInt(document.getElementById('maxFileSizeMB').value),
          reqMaxUses: parseInt(document.getElementById('maxUses').value),
          reqExpiresAt: null
        };
        fetch('/api/admin/create', {
          method: 'POST',
          headers: {'Content-Type': 'application/json'},
          body: JSON.stringify(data)
        })
        .then(r => r.json())
        .then(res => {
          document.getElementById('uploadLink').href = res.uploadUrl;
          document.getElementById('uploadLink').innerText = res.uploadUrl;
          document.getElementById('receiveLink').href = res.receiveUrl;
          document.getElementById('receiveLink').innerText = res.receiveUrl;
          document.getElementById('otpText').innerText = res.portalOtp;
          document.getElementById('resultBox').classList.remove('hidden');
        })
        .catch(err => alert('Failed to create portal: ' + err));
      }

      function copyLink(elementId, btn) {
        const url = document.getElementById(elementId).href;
        navigator.clipboard.writeText(url).then(() => {
          const originalText = btn.innerText;
          btn.innerText = 'Copied!';
          btn.style.background = '\#dcfce7';
          btn.style.color = '\#16a34a';
          setTimeout(() => {
            btn.innerText = originalText;
            btn.style.background = '\#e2e8f0';
            btn.style.color = '\#334155';
          }, 1500);
        }).catch(err => alert('Failed to copy: ' + err));
      }
    </script>
  </body>
</html>
|]

uploadHTML :: T.Text -> T.Text
uploadHTML token = [i|<!DOCTYPE html>
<html>
  <head>
    <meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>Upload Portal - OTP Required</title>
    #{styleHTML}
  </head>
  <body>
    <div class="card">
      <div id="otpScreen" style="text-align:center;">
        <h2>Enter Access OTP</h2>
        <p style="font-size:0.85rem; color:\#64748b;">Please enter the One-Time Passcode provided by the administrator.</p>
        <input type="text" id="otpInput" placeholder="------" maxlength="6">
        <br>
        <button onclick="verifyOtp()">Access Portal</button>
        <div id="otpError" style="color:\#dc2626; font-size:0.85rem; margin-top:0.75rem;"></div>
      </div>
      <div id="uploadScreen" class="hidden">
        <h2>Secure Upload Portal</h2>
        <div class="dropzone" id="dz">
          <p>Drag & Drop files here, or tap to browse</p>
          <input type="file" id="fileInput" multiple style="display:none;">
        </div>
        <div id="status"></div>
      </div>
    </div>
    <script>
      const token = '#{token}';
      function verifyOtp() {
        const otp = document.getElementById('otpInput').value;
        fetch('/api/auth/' + token, { method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({authOtp: otp}) })
          .then(r => {
             if(r.ok) {
               document.getElementById('otpScreen').classList.add('hidden');
               document.getElementById('uploadScreen').classList.remove('hidden');
               initUpload();
             } else {
               document.getElementById('otpError').innerText = 'Invalid OTP code. Try again.';
             }
          }).catch(() => { document.getElementById('otpError').innerText = 'Authentication error.'; });
      }
      function initUpload() {
        const dz = document.getElementById('dz');
        const fileInput = document.getElementById('fileInput');
        const statusDiv = document.getElementById('status');
        dz.onclick = () => fileInput.click();
        ['dragenter', 'dragover'].forEach(e => dz.addEventListener(e, (ev) => { ev.preventDefault(); dz.classList.add('dragover'); }));
        ['dragleave', 'drop'].forEach(e => dz.addEventListener(e, (ev) => { ev.preventDefault(); dz.classList.remove('dragover'); }));
        dz.addEventListener('drop', (e) => handleFiles(e.dataTransfer.files));
        fileInput.onchange = (e) => handleFiles(e.target.files);
        function handleFiles(files) {
          if(!files.length) return;
          statusDiv.style.color = '\#2563eb';
          statusDiv.innerText = 'Uploading...';
          const fd = new FormData();
          for(let f of files) fd.append('files', f);
          fetch('/api/upload/' + token, { method: 'POST', body: fd })
            .then(async r => {
               if(r.ok) { statusDiv.style.color = '\#16a34a'; statusDiv.innerText = '✓ Uploaded Successfully!'; }
               else { statusDiv.style.color = '\#dc2626'; statusDiv.innerText = await r.text(); }
            }).catch(() => { statusDiv.style.color = '\#dc2626'; statusDiv.innerText = 'Upload failed.'; });
        }
      }
    </script>
  </body>
</html>
|]

receiveHTML :: T.Text -> T.Text
receiveHTML token = [i|<!DOCTYPE html>
<html>
  <head>
    <meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>Receive Portal - OTP Required</title>
    #{styleHTML}
  </head>
  <body>
    <div class="card">
      <div id="otpScreen" style="text-align:center;">
        <h2>Enter Receiver OTP</h2>
        <p style="font-size:0.85rem; color:\#64748b;">Please enter the One-Time Passcode to view received files.</p>
        <input type="text" id="otpInput" placeholder="------" maxlength="6">
        <button onclick="verifyOtp()">Unlock Dashboard</button>
        <div id="otpError" style="color:\#dc2626; font-size:0.85rem; margin-top:0.75rem;"></div>
      </div>
      <div id="receiveScreen" class="hidden">
        <h2>Received Files</h2>
        <div id="info">Waiting for uploads... (Live updating)</div>
        <ul id="fileList"></ul>
      </div>
    </div>
    <script>
      const token = '#{token}';
      function verifyOtp() {
        const otp = document.getElementById('otpInput').value;
        fetch('/api/auth/' + token, { method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({authOtp: otp}) })
          .then(r => {
             if(r.ok) {
               document.getElementById('otpScreen').classList.add('hidden');
               document.getElementById('receiveScreen').classList.remove('hidden');
               initReceive();
             } else {
               document.getElementById('otpError').innerText = 'Invalid OTP code. Try again.';
             }
          }).catch(() => { document.getElementById('otpError').innerText = 'Authentication error.'; });
      }
      function initReceive() {
        function pollStatus() {
          fetch('/api/status/' + token)
            .then(r => r.json())
            .then(data => {
               const list = document.getElementById('fileList');
               const info = document.getElementById('info');
               if(data.psFiles && data.psFiles.length > 0) {
                 info.innerText = 'Uploaded: ' + data.psCurrentUses + ' / ' + data.psMaxUses + ' session uses';
                 list.innerHTML = data.psFiles.map(f =>
                   '<li>' +
                     '<span><b>' + f.fileNameStr + '</b> (' + (f.fileSize/1024).toFixed(1) + ' KB)</span>' +
                     '<div style="display:flex; gap:0.5rem; align-items:center;">' +
                       '<span class="badge">✓ Ready</span>' +
                       '<a class="btn" href="/api/download/#{token}/' + f.fileNameStr + '" download>Download</a>' +
                     '</div>' +
                   '</li>'
                 ).join('');
               }
            }).catch(err => console.error(err));
        }
        setInterval(pollStatus, 2000);
        pollStatus();
      }
    </script>
  </body>
</html>
|]
