return function(mod)
 local Strings=require('src.core.Strings')
 local function label(source)return Strings(source,'touch_tools')end
 local T=require('src.core.TouchControls')
 local Safe=require('src.core.SafeArea')
 local captured,owner={},nil
 local font,fontSize
 local function visible()
  return mod.game and T.active and T.enabled~=false and not T.preview
   and not T.controllerHidden and T:visible()and T:hotbarShown()
 end
 local function renderer()
  local e=mod.game and mod.game.mods and mod.game.mods.exports or{}
  local r=e.gmarcs_gen2_voxel_mod or e.GEN2_VOXEL or e.DRAMATIC_SHAPE
  if not r then for _,candidate in pairs(e)do
   if type(candidate)=='table'and type(candidate.lib)=='table'
    and type(candidate.lib.require)=='function'and candidate.lib.mod then r=candidate;break end
  end end
  return r and r.lib
 end
 local fpZoom=1
 local hookedFP
 local function zoom(direction)
  local V=renderer()
  if V and type(V.require)=='function'then
   local C=V.require('CamControl')
   if C.zoomTarget()then return C.zoomBy(direction)end
   local P=require('src.render.Pipelines')
   if P.level('voxel')==6 then
    local F=V.require('FirstPerson')
    if hookedFP~=F then
     local frame=F.frame
     F.frame=function(...)
      local rig,x,z=frame(...)
      if rig and rig.fov and P.level('voxel')==6 then rig.fov=rig.fov*fpZoom end
      return rig,x,z
     end
     hookedFP=F
    end
    fpZoom=math.max(.7,math.min(1.25,fpZoom+direction*.1));return true
   end
  end
  local g=mod.game
  if g.zoomStep then g:zoomStep(-direction)else g:keypressed('4');g:keyreleased('4')end
  return true
 end
 local function pipeline()
  if not renderer()then return nil end
  local P=require('src.render.Pipelines');return P.get('voxel')and P or nil
 end
 local function speed()return mod.game and mod.game:logicSpeed()or 1 end
 local function toggle()
  local g=mod.game;if not g or g:speedLocked()then return false end
  g.speedOverride=speed()>1 and 1 or 4;return true
 end
 local function voxelLabel()
  local P=pipeline();if not P then return nil end
  local n=P.level('voxel');return label(n==0 and'2D'or n==6 and'1ST'or n==7 and'3RD'or'3D')
 end
 local function cycleVoxel()
  local g=mod.game;local P=pipeline();local w=g and(g.world or g.overworld)
  if not P or not P.canToggle('voxel',g.stack:top()or w,w)then return false end
  local n=P.level('voxel');P.setLevel('voxel',n==0 and 3 or n<6 and 6 or n==6 and 7 or 3)
  P.syncOptions(g.save.options)
  if g.options and g.options~=g.save.options then P.syncOptions(g.options)end
  local opts=g.options or g.save.options
  if opts.tilt~=nil then require('src.render.Tilt').setLevel(opts.tilt)end
  if g.persistOptions then g:persistOptions()end
  return true
 end
 local function rows()
  local r={{id='speed',label=Strings.translate('SPEED %gx','touch_tools',speed())or('SPEED %gx'):format(speed())},
   {id='save',label=label('SAVE')},{id='load',label=label('LOAD')},
   {id='color',label=label('COLOR')},{id='zoomIn',label=label('ZOOM +')},{id='zoomOut',label=label('ZOOM -')}}
  r[#r+1]=pipeline()and{id='voxel',label='VOXEL '..voxelLabel()}or{id='tilt',label=label('TILT')}
  local V=renderer()
  if V and V.mod and mod.game.mods.optionSchemas and mod.game.mods.optionSchemas[V.mod.id]then
   r[#r+1]={id='voxelSettings',label=label('VOXEL SETTINGS')}
  end
  return r
 end
 local function cells()
  if not visible()or not T.hotbarOpen then return{}end
  local x,y,w,h=Safe.windowRect();local z=T:layout().hotbar
  local list=rows();local gap=3;local rh=math.min(30,math.max(22,(h-24)/#list-gap))
  local width=math.min(w-12,148);local height=#list*(rh+gap)-gap
  local left=math.max(x+6,math.min(z.cx+z.w/2-width,x+w-width-6))
  local top=math.max(y+6,math.min(z.cy+z.w*.8,y+h-height-6))
  for i,r in ipairs(list)do r.x,r.y,r.w,r.h=left,top+(i-1)*(rh+gap),width,rh;r.ctl=r end
  return list
 end
 local function inside(b,x,y)return x>=b.x and x<=b.x+b.w and y>=b.y and y<=b.y+b.h end
 local function at(x,y)for _,r in ipairs(cells())do if inside(r,x,y)then return r end end end
 local function run(id)
  if id=='speed'then return toggle()end
  if id=='voxel'then return cycleVoxel()end
  if id=='voxelSettings'then
   local V=renderer();local g=mod.game
   local schema=V and V.mod and g.mods.optionSchemas[V.mod.id]
   if not schema then return false end
   local screen=require('src.mods.ManagerState').new(g)
   screen.optionRows=screen:buildOptionRows({id=V.mod.id},schema)
   screen.screen,screen.cursor,screen.scroll='options',1,0
   g.stack:push(screen);return true
  end
  if id=='zoomIn'or id=='zoomOut'then return zoom(id=='zoomIn'and -1 or 1)end
  local keys={save='f1',load='f2',color='2',zoom='4',tilt='3'}
  local g=mod.game
  if(id=='save'or id=='load')and g.quickSaveAllowed and not g:quickSaveAllowed()then return false end
  local key=keys[id];if not key then return false end
  -- Route to the live game, bypassing launcher routing and key rebinding.
  g:keypressed(key);g:keyreleased(key);return true
 end
 local hit,press,move,release,reset,draw=T.hitTest,T.touchpressed,T.touchmoved,T.touchreleased,T.reset,T.draw
 T.hotbarStrip=function()return cells()end
 T.hitTest=function(self,x,y,...)
  if at(x,y)then return'touch_tools'end;return hit(self,x,y,...)
 end
 T.touchpressed=function(self,id,x,y,...)
  local row=at(x,y)
  if row then captured[id]=row.id;if owner==nil then owner=id end;return true end
  if visible()and self.hotbarOpen then
   local z=self:layout().hotbar
   if math.abs(x-z.cx)>z.w*.8 or math.abs(y-z.cy)>z.w*.8 then
    self.hotbarOpen=false;captured[id]='dismiss';return true
   end
  end
  return press(self,id,x,y,...)
 end
 T.touchmoved=function(self,id,...)
  if captured[id]then return true end;return move(self,id,...)
 end
 T.touchreleased=function(self,id,x,y,...)
  local kind=captured[id]
  if kind then
   captured[id]=nil
   if owner==id then
    owner=nil;local row=at(x,y)
    if row and row.id==kind and run(kind)then self.hotbarOpen=false end
   end
   return true
  end
  return release(self,id,x,y,...)
 end
 T.reset=function(self,...)
  captured,owner={},nil;self.hotbarOpen=false;return reset(self,...)
 end
 T.draw=function(self,...)
  local open=self.hotbarOpen;self.hotbarOpen=false;draw(self,...);self.hotbarOpen=open
  local list=cells();if #list==0 then return end
  local G=love.graphics;local size=math.max(10,math.floor(list[1].h*.42))
  if fontSize~=size then if font and font.release then font:release()end;font=G.newFont(size);fontSize=size end
  G.push('all');G.origin();G.setShader();G.setScissor();G.setFont(font)
  local a,b=list[1],list[#list]
  G.setColor(.06,.07,.09,.96);G.rectangle('fill',a.x-4,a.y-4,a.w+8,b.y+b.h-a.y+8,7,7)
  for _,r in ipairs(list)do
   local selected=owner and captured[owner]==r.id
   G.setColor(selected and .35 or .17,.20,.24,.98);G.rectangle('fill',r.x,r.y,r.w,r.h,4,4)
   G.setColor(1,1,1,1);G.printf(r.label,r.x+8,r.y+(r.h-font:getHeight())/2,r.w-16,'left')
  end
  G.pop()
 end
 mod.exports.bounds=function()return nil end
 mod.exports.cells=cells;mod.exports.dispatch=run
 mod.exports.label=function()return('%gx'):format(speed())end
 mod.exports.toggle=toggle;mod.exports.voxelLabel=voxelLabel;mod.exports.cycleVoxel=cycleVoxel
end
