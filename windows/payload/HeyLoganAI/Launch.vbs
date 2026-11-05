Option Explicit
' ---------------------------------------------------------------------------
' Hey Logan AI - launcher
'
' Starts the local bridge server in the background (if it is not already
' running) and opens the app in a dedicated chromium-based app window.
'
' The window uses a private browser profile (<install>\browser-profile):
'   * a microphone permission exception for our localhost origins is seeded
'     into the profile on first run, so wake-word listening starts without a
'     permission prompt;
'   * --autoplay-policy=no-user-gesture-required lets the spoken reply
'     ("Logan here.") play at logon without a click.
' The user's normal Edge/Chrome profile is not touched and no "unsupported
' command-line flag" bar is shown (no fake-UI media flag).
' No console windows are shown.
' ---------------------------------------------------------------------------
Dim fso, sh, env, root, nodeExe, appDir, entry, profileDir
Dim healthUrl, baseUrl, httpPort, httpsPort, i, healthy, token, url
Dim browser, browserArgs, lastError

Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
Set env = sh.Environment("PROCESS")

root = fso.GetParentFolderName(WScript.ScriptFullName)
nodeExe = root & "\runtime\node.exe"
appDir = root & "\app"
entry = appDir & "\server\index.js"
profileDir = root & "\browser-profile"

' Port overrides are used by automated tests only; production uses 8787/8443.
httpPort = 8787
If Len(env("HEY_AI_HTTP_PORT")) > 0 Then
  If IsNumeric(env("HEY_AI_HTTP_PORT")) Then httpPort = CLng(env("HEY_AI_HTTP_PORT"))
End If
httpsPort = 8443
If Len(env("HEY_AI_HTTPS_PORT")) > 0 Then
  If IsNumeric(env("HEY_AI_HTTPS_PORT")) Then httpsPort = CLng(env("HEY_AI_HTTPS_PORT"))
End If
healthUrl = "http://127.0.0.1:" & httpPort & "/api/health"
baseUrl = "http://127.0.0.1:" & httpPort & "/"

If Not fso.FileExists(nodeExe) Then
  MsgBox "The bundled Node.js runtime is missing:" & vbCrLf & nodeExe & vbCrLf & vbCrLf & _
         "Please reinstall Hey Logan AI.", 16, "Hey Logan AI"
  WScript.Quit 1
End If

If Not fso.FileExists(entry) Then
  MsgBox "The application files are missing:" & vbCrLf & entry & vbCrLf & vbCrLf & _
         "Please reinstall Hey Logan AI.", 16, "Hey Logan AI"
  WScript.Quit 1
End If

' --- private browser profile (keeps the microphone permission) -------------
If Not fso.FolderExists(profileDir) Then
  On Error Resume Next
  fso.CreateFolder profileDir
  Err.Clear
  On Error GoTo 0
End If
EnsureProfilePreferences

' --- already running? ------------------------------------------------------
healthy = False
If HealthOk() Then healthy = True

' --- start it --------------------------------------------------------------
If Not healthy Then
  On Error Resume Next
  sh.CurrentDirectory = appDir
  sh.Run """" & nodeExe & """ """ & entry & """", 0, False
  If Err.Number <> 0 Then
    Err.Clear
    MsgBox "Could not start the Hey Logan AI server." & vbCrLf & _
           "Please reinstall Hey Logan AI, or run ""Start Console.cmd"" to see the error.", 16, "Hey Logan AI"
    WScript.Quit 1
  End If
  On Error GoTo 0

  For i = 1 To 75
    WScript.Sleep 250
    If HealthOk() Then
      healthy = True
      Exit For
    End If
  Next
End If

If Not healthy Then
  MsgBox "Hey Logan AI did not finish starting." & vbCrLf & vbCrLf & _
         "Open ""Start Console.cmd"" in:" & vbCrLf & root & vbCrLf & vbCrLf & _
         "to see the error. The most common cause is another program already " & _
         "using port " & httpPort & ".", 48, "Hey Logan AI"
  WScript.Quit 1
End If

' --- open the app window ---------------------------------------------------
token = ReadToken()
url = baseUrl
If Len(token) > 0 Then url = url & "?token=" & token

OpenAppWindow url
WScript.Quit 0

' ===========================================================================
' Seed the dedicated profile with a microphone permission exception for our
' own localhost origins (only when the browser has not written its own
' Preferences file yet). This is what makes SpeechRecognition.start() succeed
' at logon with no permission prompt. The grant covers only the local app.
' ===========================================================================
Sub EnsureProfilePreferences()
  Dim defaultDir, prefPath, stream, json
  defaultDir = profileDir & "\Default"
  prefPath = defaultDir & "\Preferences"
  If fso.FileExists(prefPath) Then Exit Sub
  If Not fso.FolderExists(defaultDir) Then
    On Error Resume Next
    fso.CreateFolder defaultDir
    Err.Clear
    On Error GoTo 0
  End If
  json = PreferencesJson()
  On Error Resume Next
  Set stream = fso.CreateTextFile(prefPath, True, False)
  stream.Write json
  stream.Close
  Err.Clear
  On Error GoTo 0
End Sub

Function PreferencesJson()
  Dim q
  q = Chr(34)
  PreferencesJson = "{" & q & "profile" & q & ":{" & q & "content_settings" & q & ":{" & q & "exceptions" & q & ":{" & q & "media_stream_mic" & q & ":{"
  PreferencesJson = PreferencesJson & q & "http://127.0.0.1:" & httpPort & ",*" & q & ":{" & q & "setting" & q & ":1," & q & "last_modified" & q & ":" & q & "13370000000000000" & q & "},"
  PreferencesJson = PreferencesJson & q & "https://127.0.0.1:" & httpsPort & ",*" & q & ":{" & q & "setting" & q & ":1," & q & "last_modified" & q & ":" & q & "13370000000000000" & q & "},"
  PreferencesJson = PreferencesJson & q & "https://localhost:" & httpsPort & ",*" & q & ":{" & q & "setting" & q & ":1," & q & "last_modified" & q & ":" & q & "13370000000000000" & q & "}"
  PreferencesJson = PreferencesJson & "}}}}}"
End Function

' ===========================================================================
' Returns True when the local bridge answers /api/health and identifies
' itself as Hey Logan AI. Err is always cleared before the result is read,
' because some MSXML objects raise (harmless) errors for optional methods.
Function HealthOk()
  Dim http, ok, body, status
  HealthOk = False
  ok = False
  On Error Resume Next

  Set http = CreateObject("MSXML2.ServerXMLHTTP.6.0")
  Err.Clear
  If Not IsObject(http) Then
    Set http = CreateObject("MSXML2.XMLHTTP.6.0")
    Err.Clear
  End If
  If Not IsObject(http) Then
    On Error GoTo 0
    Exit Function
  End If

  ' Timeouts are supported by ServerXMLHTTP; the call is harmless if missing.
  http.setTimeouts 300, 300, 500, 1200
  Err.Clear

  http.Open "GET", healthUrl, False
  Err.Clear

  http.Send
  If Err.Number = 0 Then
    status = 0
    body = ""
    status = http.Status
    body = http.responseText
    If status = 200 Then
      If InStr(1, body, "Hey Logan AI", 1) > 0 Then ok = True
    End If
  End If

  Err.Clear
  On Error GoTo 0
  HealthOk = ok
End Function

Function ReadToken()
  Dim cfgPath, stream, text, re, m
  ReadToken = ""
  cfgPath = appDir & "\data\config.json"
  If Not fso.FileExists(cfgPath) Then Exit Function
  On Error Resume Next
  Set stream = fso.OpenTextFile(cfgPath, 1, False)
  text = stream.ReadAll
  stream.Close
  Err.Clear
  Set re = New RegExp
  re.Pattern = """token""\s*:\s*""([^""]+)"""
  re.IgnoreCase = True
  Set m = re.Execute(text)
  If m.Count > 0 Then ReadToken = m(0).SubMatches(0)
  Err.Clear
  On Error GoTo 0
End Function

Sub OpenAppWindow(targetUrl)
  Dim pf, pf86, localAppData, candidates, k, q
  q = Chr(34)
  pf = sh.ExpandEnvironmentStrings("%ProgramFiles%")
  pf86 = sh.ExpandEnvironmentStrings("%ProgramFiles(x86)%")
  localAppData = sh.ExpandEnvironmentStrings("%LocalAppData%")

  candidates = Array( _
      pf86 & "\Microsoft\Edge\Application\msedge.exe", _
      pf & "\Microsoft\Edge\Application\msedge.exe", _
      pf86 & "\Google\Chrome\Application\chrome.exe", _
      pf & "\Google\Chrome\Application\chrome.exe", _
      localAppData & "\Google\Chrome\Application\chrome.exe")

  browser = ""
  For k = LBound(candidates) To UBound(candidates)
    If fso.FileExists(candidates(k)) Then
      browser = candidates(k)
      Exit For
    End If
  Next

  On Error Resume Next
  lastError = 0
  If Len(browser) > 0 Then
    browserArgs = "--app=" & targetUrl & _
                  " --window-size=1180,840" & _
                  " --user-data-dir=" & q & profileDir & q & _
                  " --no-first-run" & _
                  " --no-default-browser-check" & _
                  " --autoplay-policy=no-user-gesture-required"
    sh.Run q & browser & q & " " & browserArgs, 1, False
    lastError = Err.Number
    Err.Clear
    If lastError = 0 Then
      On Error GoTo 0
      Exit Sub
    End If
  End If

  ' Fall back to whatever browser is registered for http:// URLs.
  sh.Run targetUrl, 1, False
  lastError = Err.Number
  Err.Clear
  On Error GoTo 0

  If lastError <> 0 Then
    MsgBox "Hey Logan AI is running, but the app window could not be opened." & vbCrLf & _
           "Open this address in your browser:" & vbCrLf & vbCrLf & targetUrl, 48, "Hey Logan AI"
  End If
End Sub
