# roblox-to-rojo
A Lune script that attempts to convert a Roblox .rbxl(x) place file to Rojo-style format (for *fully*-managed projects).

Please note I only made this for **personal use**, so it may be quite buggy and incomplete, however I bet it can do at least 80% of the work for you.
You'll have to fork this repository yourself if you want to add any changes since I won't be actively maintaining it.

This tool is different from https://github.com/rojo-rbx/rbxlx-to-rojo in
that it supports a fully-managed rojo workflow as opposed to only
partially-managed. Again, this tool isn't perfect but I think it does the job pretty well.

Best results occur when all your game scripts are stored in one of these
containers: Directly under a Service, Folders, Models, Configurations.
If your scripts are stored anywhere else (e.g. under a Part as a touch
damage script, or under a Gui instance.), conversion may not be fully
complete.

"meta files" and "meta.json" both mean the same thing in relation to this
README.md

# Usage
1. Install aftman and both selene + stylua VS Code extensions.
2. Clone the repository and run `aftman install`
3. Place a .rbxl(x) place file inside the repo folder.
4. If your place file is named "game.rbxl" you can skip this step, otherwise rename the place file or go to `.lune/roblox-to-rojo.lua` and modify the `PLACE_FILE_PATH` constant to match your place file name.
5. Modify the settings inside `.lune/roblox-to-rojo.lua` as you desire.
6. Run `lune roblox-to-rojo.lua`

# How the conversion process works
- If the instance is a Script AND has no children -> save as script (.lua)
- If the instance is a Script AND has children / Not a script AND contains
    scripts (descendants) -> save as folder (either init*.lua or meta.json)
- If the instance is not a script AND doesn't contain any scripts
    (descendants) -> save as model (.rbxm)

# Current features
- You can specify which services to save if you don't want to do a full
    conversion.
- Recursively loops through the place's services and automatically creates
    everything such as the required folders, scripts, model/meta.jsons, rbxms
    etc. as outlined in https://rojo.space/docs/v7/sync-details/
- (WIP) Preserves scripts/local scripts Disabled property using meta.jsons
- Preserves instance AND service-specific (WIP) attributes.
- Preserves instance AND service-specific (WIP) tags.
- Creates a new project.json file that specifies the properties
    and sub-services (like StarterPlayer/StarterPlayerScripts) of all
    services defined in CONTAINERS
- Only saves properties that aren't already set to a default value (most of the time).
- You can force specific instances to be saved as a model file in case
    the conversion process goes bad for those specific instances. You can
    provide either an instance name or an exact path in FORCE_SAVE_AS_MODEL:
    - `Name = "Vehicles"`
    - `Path = "Workspace.Vehicles"`


# Potential future features
* Automatic wally package linking in project.json

# Caveats
- Instance names with any of the following characters will get replaced by
    an underscore (_): \ / : * ? "< > |
    This is a restriction of Windows.
- Does not preserve Ref values in meta files (e.g. Model.PrimaryPart,
    Sound.SoundGroup) isn't possible yet. A way to fix this is to remove any
    scripts under the instance that has a Ref value so it can be saved as a
    model file (.rbxm) instead (which WILL preserve Refs as long as they
    are a child of the instance).
- Does not preserve PackageLinks (they are deleted when converting atm.)
- CFrame attributes aren't supported by rojo yet, so they are automatically
    converted into strings in `rojoifyValue`