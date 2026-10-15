; AgentBarBar inline Chinese/English UI. Adapted from bundled NSIS English/SimpChinese translations; original credits retained.
;Language: English (1033)
;By Joost Verburg

!insertmacro LANGFILE "English" "English" "English" "English" ; See \Include\LangFile.nsh for a description of these parameters

!ifdef MUI_WELCOMEPAGE
  ${LangFileString} MUI_TEXT_WELCOME_INFO_TITLE "欢迎使用 AgentBarBar$\r$\nWelcome to AgentBarBar"
  ${LangFileString} MUI_TEXT_WELCOME_INFO_TEXT "本程序将为当前用户安装 AgentBarBar。$\r$\nInstall AgentBarBar for your Windows account.$\r$\n$\r$\n安装前，请先从系统托盘退出 AgentBarBar。$\r$\nQuit AgentBarBar from its tray before installing.$\r$\n$\r$\n点击“下一步 / Next”继续。$\r$\nClick Next to continue."
!endif

!ifdef MUI_UNWELCOMEPAGE
  ${LangFileString} MUI_UNTEXT_WELCOME_INFO_TITLE "欢迎使用 $(^NameDA) 卸载程序 / Welcome to $(^NameDA) Uninstall"
  ${LangFileString} MUI_UNTEXT_WELCOME_INFO_TEXT "此程序将引导你完成 $(^NameDA) 的卸载。$\r$\n$\r$\n在卸载之前，请确认 $(^NameDA) 已经关闭。$\r$\n$\r$\n$_CLICK / Setup will guide you through the uninstallation of $(^NameDA).$\r$\n$\r$\nBefore starting the uninstallation, make sure $(^NameDA) is not running.$\r$\n$\r$\n$_CLICK"
!endif

!ifdef MUI_LICENSEPAGE
  ${LangFileString} MUI_TEXT_LICENSE_TITLE "许可证协议 / License Agreement"
  ${LangFileString} MUI_TEXT_LICENSE_SUBTITLE "在安装 $(^NameDA) 之前，请阅读许可证条款。 / Please review the license terms before installing $(^NameDA)."
  ${LangFileString} MUI_INNERTEXT_LICENSE_BOTTOM "如果你接受许可证的条款，请点击 [我同意(I)] 继续安装。你必须在同意后才能安装 $(^NameDA) 。 / If you accept the terms of the agreement, click I Agree to continue. You must accept the agreement to install $(^NameDA)."
  ${LangFileString} MUI_INNERTEXT_LICENSE_BOTTOM_CHECKBOX "如果你接受许可证的条款，请点击勾选下方的选框。你必须在同意后才能安装 $(^NameDA)。$_CLICK / If you accept the terms of the agreement, click the check box below. You must accept the agreement to install $(^NameDA). $_CLICK"
  ${LangFileString} MUI_INNERTEXT_LICENSE_BOTTOM_RADIOBUTTONS "如果你接受许可证的条款，请选择下方第一个选项。你必须在同意后才能安装 $(^NameDA)。$_CLICK / If you accept the terms of the agreement, select the first option below. You must accept the agreement to install $(^NameDA). $_CLICK"
!endif

!ifdef MUI_UNLICENSEPAGE
  ${LangFileString} MUI_UNTEXT_LICENSE_TITLE "许可证协议 / License Agreement"
  ${LangFileString} MUI_UNTEXT_LICENSE_SUBTITLE "在卸载 $(^NameDA) 之前，请阅读许可证条款。 / Please review the license terms before uninstalling $(^NameDA)."
  ${LangFileString} MUI_UNINNERTEXT_LICENSE_BOTTOM "如果你接受许可证的条款，请点击 [我同意(I)] 继续卸载。如果你点击 [取消(C)] ，卸载程序将会关闭。你必须在同意后才能卸载 $(^NameDA) 。 / If you accept the terms of the agreement, click I Agree to continue. You must accept the agreement to uninstall $(^NameDA)."
  ${LangFileString} MUI_UNINNERTEXT_LICENSE_BOTTOM_CHECKBOX "如果你接受许可证的条款，点击勾选下方的选框。你必须在同意后才能卸载 $(^NameDA)。$_CLICK / If you accept the terms of the agreement, click the check box below. You must accept the agreement to uninstall $(^NameDA). $_CLICK"
  ${LangFileString} MUI_UNINNERTEXT_LICENSE_BOTTOM_RADIOBUTTONS "如果你接受许可证的条款，请选择下方第一个选项。你必须在同意后才能卸载 $(^NameDA)。$_CLICK / If you accept the terms of the agreement, select the first option below. You must accept the agreement to uninstall $(^NameDA). $_CLICK"
!endif

!ifdef MUI_LICENSEPAGE | MUI_UNLICENSEPAGE
  ${LangFileString} MUI_INNERTEXT_LICENSE_TOP "要阅读协议的其余部分，请按 [PgDn] 键向下翻页。 / Press Page Down to see the rest of the agreement."
!endif

!ifdef MUI_COMPONENTSPAGE
  ${LangFileString} MUI_TEXT_COMPONENTS_TITLE "选择组件 / Choose Components"
  ${LangFileString} MUI_TEXT_COMPONENTS_SUBTITLE "选择你想安装的 $(^NameDA) 功能组件。 / Choose which features of $(^NameDA) you want to install."
!endif

!ifdef MUI_UNCOMPONENTSPAGE
  ${LangFileString} MUI_UNTEXT_COMPONENTS_TITLE "选择组件 / Choose Components"
  ${LangFileString} MUI_UNTEXT_COMPONENTS_SUBTITLE "选择你想卸载的 $(^NameDA) 功能组件。 / Choose which features of $(^NameDA) you want to uninstall."
!endif

!ifdef MUI_COMPONENTSPAGE | MUI_UNCOMPONENTSPAGE
  ${LangFileString} MUI_INNERTEXT_COMPONENTS_DESCRIPTION_TITLE "组件描述 / Description"
  !ifndef NSIS_CONFIG_COMPONENTPAGE_ALTERNATIVE
    ${LangFileString} MUI_INNERTEXT_COMPONENTS_DESCRIPTION_INFO "点击选中组件，即可显示它的功能描述。 / Position your mouse over a component to see its description."
  !else
    ${LangFileString} MUI_INNERTEXT_COMPONENTS_DESCRIPTION_INFO "点击选中组件，即可显示它的功能描述。 / Select a component to see its description."
  !endif
!endif

!ifdef MUI_DIRECTORYPAGE
  ${LangFileString} MUI_TEXT_DIRECTORY_TITLE "选择安装位置 / Choose Install Location"
  ${LangFileString} MUI_TEXT_DIRECTORY_SUBTITLE "选择安装目录。 / Choose an installation folder."
!endif

!ifdef MUI_UNDIRECTORYPAGE
  ${LangFileString} MUI_UNTEXT_DIRECTORY_TITLE "选择卸载位置 / Choose Uninstall Location"
  ${LangFileString} MUI_UNTEXT_DIRECTORY_SUBTITLE "选择 $(^NameDA) 的卸载文件夹。 / Choose the folder from which to uninstall $(^NameDA)."
!endif

!ifdef MUI_INSTFILESPAGE
  ${LangFileString} MUI_TEXT_INSTALLING_TITLE "正在安装 / Installing"
  ${LangFileString} MUI_TEXT_INSTALLING_SUBTITLE "正在安装，请稍候。 / Installing, please wait."
  ${LangFileString} MUI_TEXT_FINISH_TITLE "安装完成 / Installation Complete"
  ${LangFileString} MUI_TEXT_FINISH_SUBTITLE "安装程序成功完成安装。 / Setup was completed successfully."
  ${LangFileString} MUI_TEXT_ABORT_TITLE "安装中止 / Installation Aborted"
  ${LangFileString} MUI_TEXT_ABORT_SUBTITLE "安装程序未能完成安装。 / Setup was not completed successfully."
!endif

!ifdef MUI_UNINSTFILESPAGE
  ${LangFileString} MUI_UNTEXT_UNINSTALLING_TITLE "正在卸载 / Uninstalling"
  ${LangFileString} MUI_UNTEXT_UNINSTALLING_SUBTITLE "正在卸载，请稍候。 / Uninstalling, please wait."
  ${LangFileString} MUI_UNTEXT_FINISH_TITLE "卸载完成 / Uninstallation Complete"
  ${LangFileString} MUI_UNTEXT_FINISH_SUBTITLE "卸载程序成功完成卸载。 / Uninstall was completed successfully."
  ${LangFileString} MUI_UNTEXT_ABORT_TITLE "卸载中止 / Uninstallation Aborted"
  ${LangFileString} MUI_UNTEXT_ABORT_SUBTITLE "卸载程序未能完成卸载。 / Uninstall was not completed successfully."
!endif

!ifdef MUI_FINISHPAGE
  ${LangFileString} MUI_TEXT_FINISH_INFO_TITLE "安装完成$\r$\nInstallation complete"
  ${LangFileString} MUI_TEXT_FINISH_INFO_TEXT "AgentBarBar 已安装。$\r$\nAgentBarBar has been installed.$\r$\n$\r$\n点击“完成 / Finish”关闭安装程序。$\r$\nClick Finish to close Setup."
  ${LangFileString} MUI_TEXT_FINISH_INFO_REBOOT "必须重新启动本机才能完成 $(^NameDA) 的安装。是否立即重新启动？ / Your computer must be restarted in order to complete the installation of $(^NameDA). Do you want to reboot now?"
!endif

!ifdef MUI_UNFINISHPAGE
  ${LangFileString} MUI_UNTEXT_FINISH_INFO_TITLE "$(^NameDA) 卸载程序结束 / Completing $(^NameDA) Uninstall"
  ${LangFileString} MUI_UNTEXT_FINISH_INFO_TEXT "$(^NameDA) 已经成功从本机卸载。$\r$\n$\r$\n点击 [完成] 关闭卸载程序。 / $(^NameDA) has been uninstalled from your computer.$\r$\n$\r$\nClick Finish to close Setup."
  ${LangFileString} MUI_UNTEXT_FINISH_INFO_REBOOT "必须重新启动本机才能完成 $(^NameDA) 的卸载。是否立即重新启动？ / Your computer must be restarted in order to complete the uninstallation of $(^NameDA). Do you want to reboot now?"
!endif

!ifdef MUI_FINISHPAGE | MUI_UNFINISHPAGE
  ${LangFileString} MUI_TEXT_FINISH_REBOOTNOW "是，立即重新启动(&Y) / Reboot now"
  ${LangFileString} MUI_TEXT_FINISH_REBOOTLATER "否，我会在之后重新启动(&N) / I want to manually reboot later"
  ${LangFileString} MUI_TEXT_FINISH_RUN "启动 AgentBarBar / Run AgentBarBar"
  ${LangFileString} MUI_TEXT_FINISH_SHOWREADME "显示自述文件(&M) / &Show Readme"
  ${LangFileString} MUI_BUTTONTEXT_FINISH "完成 Finish"
!endif

!ifdef MUI_STARTMENUPAGE
  ${LangFileString} MUI_TEXT_STARTMENU_TITLE "选择开始菜单文件夹 / Choose Start Menu Folder"
  ${LangFileString} MUI_TEXT_STARTMENU_SUBTITLE "选择开始菜单文件夹，用于创建程序的快捷方式。 / Choose a Start Menu folder for the $(^NameDA) shortcuts."
  ${LangFileString} MUI_INNERTEXT_STARTMENU_TOP "选择开始菜单文件夹，用于创建程序的快捷方式。你也可以输入自定义名称，创建新文件夹。 / Select the Start Menu folder in which you would like to create the program's shortcuts. You can also enter a name to create a new folder."
  ${LangFileString} MUI_INNERTEXT_STARTMENU_CHECKBOX "不要创建快捷方式(&N) / Do not create shortcuts"
!endif

!ifdef MUI_UNCONFIRMPAGE
  ${LangFileString} MUI_UNTEXT_CONFIRM_TITLE "卸载 $(^NameDA) / Uninstall $(^NameDA)"
  ${LangFileString} MUI_UNTEXT_CONFIRM_SUBTITLE "从本机卸载 $(^NameDA) 。 / Remove $(^NameDA) from your computer."
!endif

!ifdef MUI_ABORTWARNING
  ${LangFileString} MUI_TEXT_ABORTWARNING "确定要退出 $(^Name) 安装程序吗？ / Are you sure you want to quit $(^Name) Setup?"
!endif

!ifdef MUI_UNABORTWARNING
  ${LangFileString} MUI_UNTEXT_ABORTWARNING "确定要退出 $(^Name) 卸载程序吗？ / Are you sure you want to quit $(^Name) Uninstall?"
!endif

!ifdef MULTIUSER_INSTALLMODEPAGE
  ${LangFileString} MULTIUSER_TEXT_INSTALLMODE_TITLE "选择用户 / Choose Users"
  ${LangFileString} MULTIUSER_TEXT_INSTALLMODE_SUBTITLE "选择为哪些用户安装 $(^NameDA) 。 / Choose for which users you want to install $(^NameDA)."
  ${LangFileString} MULTIUSER_INNERTEXT_INSTALLMODE_TOP "选择只为自己安装 $(^NameDA) ，还是为本机的所有用户安装。 $(^ClickNext) / Select whether you want to install $(^NameDA) only for yourself or for all users of this computer. $(^ClickNext)"
  ${LangFileString} MULTIUSER_INNERTEXT_INSTALLMODE_ALLUSERS "为本机所有用户安装(&A) / Install for anyone using this computer"
  ${LangFileString} MULTIUSER_INNERTEXT_INSTALLMODE_CURRENTUSER "只为我自己安装(&M) / Install just for me"
!endif
