(() => {
  'use strict';
  const root = document.documentElement;
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  const finePointer = matchMedia('(hover: hover) and (pointer: fine)');
  const mobile = matchMedia('(max-width: 760px)');
  const nav = document.querySelector('.section-nav');
  const navList = nav.querySelector('nav');
  const links = [...nav.querySelectorAll('[data-chapter]')];
  const headings = [...document.querySelectorAll('.chapter-heading h2')];
  const universe = document.getElementById('universe');
  const clamp = (value, min = 0, max = 1) => Math.max(min, Math.min(max, value));
  const smooth = value => value * value * (3 - 2 * value);
  root.classList.add('motion-installed');
  let heroHeight = 800, rowCenters = [], headingGeometry = [], nodeGeometry = [], universeBounds;
  let frameId = 0, scrollFrame = 0, markerY = 0, markerTarget = 0, activeIndex = 0, previousIndex = -1;
  let navReveal = 0, lastTime = 0, touchNavigationUntil = 0;
  function updateHeadingLabels() {
    headings.forEach(heading => { heading.dataset.motionLabel = heading.textContent; heading.setAttribute('aria-label', heading.textContent); });
  }
  function measure() {
    heroHeight = document.querySelector('.hero').getBoundingClientRect().height;
    rowCenters = links.map(link => link.offsetTop + link.offsetHeight / 2 - 7);
    headingGeometry = headings.map(heading => { const rect = heading.getBoundingClientRect(); return { heading, x: rect.left, y: rect.top + scrollY, width: rect.width, height: rect.height }; });
    universeBounds = universe.getBoundingClientRect();
    nodeGeometry = [...document.querySelectorAll('.orbit-item,.orbit-next,.feature-card,.feature-copy [data-feature]')].map(node => ({ node, rect: node.getBoundingClientRect() })).filter(({ rect }) => rect.bottom > 64 && rect.top < innerHeight);
  }
  function updateNavigation() {
    activeIndex = Math.max(0, links.findIndex(link => link.getAttribute('aria-current') === 'location'));
    navReveal = reduced.matches ? Number(scrollY >= heroHeight * .48) : smooth(clamp((scrollY - heroHeight * .48) / (heroHeight * .28)));
    nav.style.setProperty('--nav-opacity', String(navReveal));
    nav.classList.toggle('nav-hidden', navReveal === 0);
    nav.classList.toggle('mobile-unavailable', mobile.matches && navReveal === 0);
    nav.inert = navReveal === 0;
    links.forEach((link, index) => {
      const entry = reduced.matches ? navReveal : smooth(clamp((scrollY - heroHeight * (.48 + index * .018)) / (heroHeight * .26)));
      link.style.setProperty('--nav-entry', String(entry));
      link.classList.toggle('is-unavailable', entry < .01 && !mobile.matches);
      link.inert = !mobile.matches && entry < .01;
    });
    markerTarget = rowCenters[activeIndex] || 9;
    if (reduced.matches) markerY = markerTarget;
    if (mobile.matches && activeIndex !== previousIndex && performance.now() > touchNavigationUntil) {
      const link = links[activeIndex];
      navList.scrollTo({ left: Math.max(0, link.offsetLeft - (navList.clientWidth - link.offsetWidth) / 2), behavior: reduced.matches ? 'instant' : 'smooth' });
    }
    previousIndex = activeIndex;
    headingGeometry.forEach(({ heading, y }) => {
      const reveal = reduced.matches ? 1 : smooth(clamp((innerHeight * .82 - (y - scrollY)) / (innerHeight * .42)));
      heading.style.setProperty('--title-fill', String(reveal));
    });
  }
  navList.addEventListener('pointerdown', () => { touchNavigationUntil = performance.now() + 1400; }, { passive: true });
  let anchorFrame = 0;
  function cancelAnchorScroll() { if (anchorFrame) cancelAnimationFrame(anchorFrame); anchorFrame = 0; }
  function scrollToAnchor(hash, changeHistory = false) {
    const target = document.getElementById(hash.slice(1));
    if (!target) return;
    cancelAnchorScroll();
    const heading = target.querySelector('.chapter-heading h2') || target.querySelector('h2') || target;
    const offset = document.querySelector('.site-header').offsetHeight + (mobile.matches ? 46 : 0) + 32;
    let headingTop = 0; for (let node = heading; node; node = node.offsetParent) headingTop += node.offsetTop;
    const end = hash === '#main' ? 0 : clamp(headingTop - offset, 0, document.documentElement.scrollHeight - innerHeight);
    if (changeHistory && location.hash !== hash) history.pushState(null, '', hash);
    if (reduced.matches) { scrollTo({ top: end, behavior: 'instant' }); return; }
    const start = scrollY, distance = end - start, duration = clamp(680 + Math.abs(distance) * .055, 680, 1350), started = performance.now();
    function step(time) {
      const progress = clamp((time - started) / duration);
      const ease = progress < .5 ? 4 * progress ** 3 : 1 - (-2 * progress + 2) ** 3 / 2;
      scrollTo({ top: start + distance * ease, behavior: 'instant' });
      anchorFrame = progress < 1 ? requestAnimationFrame(step) : 0;
    }
    anchorFrame = requestAnimationFrame(step);
  }
  document.addEventListener('click', event => {
    const link = event.target.closest('a[href^="#"]');
    if (!link || event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || link.download) return;
    const hash = link.getAttribute('href');
    if (!hash || hash === '#' || !document.getElementById(hash.slice(1))) return;
    event.preventDefault(); scrollToAnchor(hash, true);
  });
  addEventListener('wheel', cancelAnchorScroll, { passive: true });
  addEventListener('touchstart', cancelAnchorScroll, { passive: true });
  addEventListener('keydown', event => { if (['PageDown', 'PageUp', 'Home', 'End', 'ArrowDown', 'ArrowUp', 'Escape'].includes(event.key)) cancelAnchorScroll(); });
  addEventListener('popstate', () => { if (!document.querySelector('dialog[open]')) scrollToAnchor(location.hash || '#main'); });

  const field = document.createElement('canvas');
  field.id = 'interaction-field'; field.setAttribute('aria-hidden', 'true'); document.body.append(field);
  const ctx = field.getContext('2d');
  let viewWidth = innerWidth, viewHeight = innerHeight, colors = {}, paletteKey = '';
  const mouse = { x: 0, y: 0, visible: false, movedAt: 0 };
  const cursor = { x: 0, y: 0, radius: 14 };
  const trail = Array.from({ length: 9 }, () => ({ x: 0, y: 0 }));
  const backgroundPoints = Array.from({ length: 46 }, (_, index) => ({ x: ((index * 97 + 51) % 997) / 997, y: ((index * 149 + 109) % 991) / 991, size: index % 9 ? 1 : 2 }));
  let hovered = null, ripple = null, sceneX = 0, sceneY = 0, sceneTargetX = 0, sceneTargetY = 0;
  const sceneLayers = [...universe.querySelectorAll('.orbit-item,.universe-preview,.universe-center')].map((node, index) => ({ node, depth: [20, 30, 15, 24, 18][index] || 18 }));
  function readColors() {
    const key = root.dataset.theme + ':' + root.dataset.stage;
    if (key === paletteKey) return;
    paletteKey = key; const style = getComputedStyle(root);
    colors = { white: style.getPropertyValue('--color-fg').trim(), soft: style.getPropertyValue('--color-soft').trim(), accent: style.getPropertyValue('--color-highlight').trim() };
  }
  function resizeField() {
    viewWidth = innerWidth; viewHeight = innerHeight;
    const dpr = Math.min(devicePixelRatio || 1, 2); field.width = Math.round(viewWidth * dpr); field.height = Math.round(viewHeight * dpr); ctx?.setTransform(dpr, 0, 0, dpr, 0, 0);
  }
  function enabled() { return finePointer.matches && !reduced.matches && !document.hidden; }
  function updateScene(factor) {
    sceneX += (sceneTargetX - sceneX) * factor; sceneY += (sceneTargetY - sceneY) * factor;
    if (Math.abs(sceneX) < .0005) sceneX = 0; if (Math.abs(sceneY) < .0005) sceneY = 0;
    sceneLayers.forEach(({ node, depth }) => {
      node.style.setProperty('--parallax-x', (sceneX * depth).toFixed(2) + 'px');
      node.style.setProperty('--parallax-y', (sceneY * depth).toFixed(2) + 'px');
      node.style.setProperty('--tilt-x', (-sceneY * 8).toFixed(2) + 'deg');
      node.style.setProperty('--tilt-y', (sceneX * 10).toFixed(2) + 'deg');
    });
    return Math.abs(sceneTargetX - sceneX) + Math.abs(sceneTargetY - sceneY) > .001;
  }
  function drawWire(from, to, alpha = .25) {
    ctx.globalAlpha = alpha; ctx.strokeStyle = colors.soft; ctx.lineWidth = .7;
    ctx.beginPath(); ctx.moveTo(from.x, from.y); ctx.bezierCurveTo(from.x + (to.x - from.x) * .4, from.y, to.x - (to.x - from.x) * .2, to.y, to.x, to.y); ctx.stroke();
  }
  function drawCorners(rect) {
    const length = 13, gap = 5;
    ctx.globalAlpha = .65; ctx.strokeStyle = colors.white; ctx.fillStyle = colors.accent; ctx.lineWidth = .8;
    [[rect.left-gap,rect.top-gap,1,1],[rect.right+gap,rect.top-gap,-1,1],[rect.left-gap,rect.bottom+gap,1,-1],[rect.right+gap,rect.bottom+gap,-1,-1]].forEach(([x,y,dx,dy]) => {
      ctx.beginPath(); ctx.moveTo(x,y+length*dy); ctx.lineTo(x,y); ctx.lineTo(x+length*dx,y); ctx.stroke(); ctx.fillRect(x-1,y-1,2,2);
    });
  }
  function drawField(time) {
    if (!ctx) return;
    ctx.clearRect(0, 0, viewWidth, viewHeight);
    if (!enabled()) return;
    readColors();
    if (scrollY > heroHeight * .6) {
      ctx.fillStyle = colors.soft; ctx.globalAlpha = .17;
      backgroundPoints.forEach(point => ctx.fillRect(point.x * viewWidth, point.y * viewHeight, point.size, point.size));
    }
    const heading = headingGeometry[activeIndex];
    if (!mobile.matches && navReveal > .2 && heading) {
      const y = heading.y - scrollY + heading.height * .5;
      if (y > 90 && y < viewHeight - 30) {
        const bounds = navList.getBoundingClientRect();
        const from = { x: bounds.right - 2, y: bounds.top + markerY + 7 };
        const to = { x: heading.x - 16, y };
        drawWire(from, to, navReveal * .2);
        ctx.fillStyle = colors.white; ctx.globalAlpha = .5; ctx.fillRect(to.x-1.5,to.y-1.5,3,3);
      }
    }
    if (mouse.visible && !document.querySelector('dialog[open]')) {
      const fading = clamp(1 - (time - mouse.movedAt - 100) / 850);
      ctx.strokeStyle = colors.soft; ctx.fillStyle = colors.white; ctx.lineWidth = .7;
      trail.forEach((point, index) => {
        const previous = index ? trail[index-1] : cursor;
        ctx.globalAlpha = (1-index/trail.length) * fading * .45;
        ctx.beginPath(); ctx.moveTo(previous.x,previous.y); ctx.lineTo(point.x,point.y); ctx.stroke();
        ctx.fillRect(point.x-1,point.y-1,index<3?2:1,index<3?2:1);
      });
      if (hovered && !hovered.closest('dialog')) {
        const rect = hovered.getBoundingClientRect();
        if (hovered.matches('.orbit-item,.universe-preview,.feature-card')) drawCorners(rect);
        if (hovered.matches('.orbit-item,.feature-card,[data-feature]')) {
          drawWire({ x: cursor.x, y: cursor.y }, { x: rect.right+5, y: rect.top-5 }, .32);
        }
      } else {
        let nearest = null, distance = 180;
        nodeGeometry.forEach(item => {
          const x = item.rect.left, y = item.rect.top;
          const candidate = Math.hypot(mouse.x-x,mouse.y-y);
          if (candidate < distance) { distance = candidate; nearest = { x, y }; }
        });
        if (nearest) { drawWire({ x: cursor.x, y: cursor.y },nearest,(1-distance/180)*.38); ctx.fillStyle=colors.accent;ctx.globalAlpha=.65;ctx.fillRect(nearest.x-2,nearest.y-2,4,4); }
      }
      ctx.globalAlpha = hovered ? .65 : .38; ctx.strokeStyle = colors.white;
      ctx.beginPath(); ctx.arc(cursor.x,cursor.y,cursor.radius,0,Math.PI*2); ctx.stroke();
      if (hovered?.matches('[data-feature],.universe-preview')) {
        ctx.globalAlpha = .7; ctx.beginPath();ctx.moveTo(cursor.x-4,cursor.y);ctx.lineTo(cursor.x+4,cursor.y);ctx.moveTo(cursor.x,cursor.y-4);ctx.lineTo(cursor.x,cursor.y+4);ctx.stroke();
      }
    }
    if (ripple) {
      const progress = clamp((time-ripple.time)/650);
      ctx.strokeStyle=colors.white;ctx.fillStyle=colors.accent;ctx.globalAlpha=(1-progress)*.5;ctx.lineWidth=.8;
      ctx.beginPath();ctx.arc(ripple.x,ripple.y,10+progress*40,0,Math.PI*2);ctx.stroke();
      for(let index=0;index<7;index++){const angle=index*Math.PI*2/7;const radius=8+progress*55;ctx.fillRect(ripple.x+Math.cos(angle)*radius-1,ripple.y+Math.sin(angle)*radius-1,2,2);}
      if(progress===1)ripple=null;
    }
    ctx.globalAlpha=1;
  }
  function tick(time) {
    frameId=0;
    if(document.hidden)return;
    const delta=Math.min(40,Math.max(8,time-(lastTime||time-16)));lastTime=time;
    const follow=1-Math.exp(-delta/70);
    markerY+=(markerTarget-markerY)*(reduced.matches?1:follow);
    nav.style.setProperty('--nav-marker-y',markerY.toFixed(2)+'px');
    let keepAnimating=Math.abs(markerTarget-markerY)>.08;
    if(enabled()) {
      keepAnimating=updateScene(follow*.8)||keepAnimating;
      const beforeX=cursor.x,beforeY=cursor.y;
      cursor.x+=(mouse.x-cursor.x)*follow;cursor.y+=(mouse.y-cursor.y)*follow;cursor.radius+=((hovered?23:14)-cursor.radius)*follow;
      trail.forEach((point,index)=>{const parent=index?trail[index-1]:cursor;point.x+=(parent.x-point.x)*follow*.7;point.y+=(parent.y-point.y)*follow*.7;});
      keepAnimating=keepAnimating||Math.abs(cursor.x-beforeX)+Math.abs(cursor.y-beforeY)>.1||(mouse.visible&&time-mouse.movedAt<1000)||!!ripple;
    }
    drawField(time);
    if(keepAnimating)schedule();
  }
  function schedule() { if(!frameId&&!document.hidden)frameId=requestAnimationFrame(tick); }
  function update() { measure();updateNavigation();schedule(); }
  document.addEventListener('pointermove',event=>{
    if(!enabled()||event.pointerType==='touch')return;
    const visible=!!event.target.closest('main')&&!event.target.closest('dialog');
    if(visible&&!mouse.visible){cursor.x=event.clientX;cursor.y=event.clientY;trail.forEach(point=>{point.x=event.clientX;point.y=event.clientY;});}
    mouse.x=event.clientX;mouse.y=event.clientY;mouse.visible=visible;mouse.movedAt=performance.now();
    hovered=visible?event.target.closest('.orbit-item,.universe-preview,.feature-card,[data-feature],.pill,.inline-link,.section-nav nav a,button'):null;
    if(visible&&event.target.closest('#universe')){sceneTargetX=clamp((event.clientX-universeBounds.left)/universeBounds.width)-.5;sceneTargetY=clamp((event.clientY-universeBounds.top)/universeBounds.height)-.5;}else{sceneTargetX=0;sceneTargetY=0;}
    schedule();
  },{passive:true});
  document.addEventListener('pointerleave',()=>{mouse.visible=false;hovered=null;sceneTargetX=0;sceneTargetY=0;schedule();});
  document.addEventListener('click',event=>{if(enabled()&&event.target.closest('main')&&!event.target.closest('input,dialog')){ripple={x:event.clientX,y:event.clientY,time:performance.now()};schedule();}});
  function syncPreferences() {
    root.classList.toggle('has-motion',!reduced.matches);
    field.hidden=!enabled();
    if(!enabled()){mouse.visible=false;hovered=null;sceneX=sceneY=sceneTargetX=sceneTargetY=0;updateScene(1);ctx?.clearRect(0,0,viewWidth,viewHeight);}
    update();
  }
  reduced.addEventListener('change',syncPreferences);finePointer.addEventListener('change',syncPreferences);mobile.addEventListener('change',update);
  document.addEventListener('visibilitychange',()=>{if(document.hidden){if(frameId)cancelAnimationFrame(frameId);frameId=0;cancelAnchorScroll();}else{lastTime=0;syncPreferences();}});
  addEventListener('scroll',()=>{if(!scrollFrame)scrollFrame=requestAnimationFrame(()=>{scrollFrame=0;update();});},{passive:true});
  addEventListener('resize',()=>{resizeField();update();});
  new ResizeObserver(update).observe(document.querySelector('.chapters'));
  new MutationObserver(()=>{updateHeadingLabels();update();}).observe(root,{attributes:true,attributeFilter:['lang']});
  updateHeadingLabels();resizeField();syncPreferences();
})();
